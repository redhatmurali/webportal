#!/usr/bin/env bash
#
# OpenObserve installer for Ubuntu 24.04
#
# Usage:
#   sudo ./install-openobserve.sh --version 0.14.7 --port 5080
#   sudo ./install-openobserve.sh -v 0.14.7 -p 5080
#   sudo OO_VERSION=0.14.7 OO_PORT=5080 ./install-openobserve.sh
#
# Only two inputs: version and port. Everything else is automatic.
# Re-running with a different version/port upgrades/reconfigures in place
# (data and credentials are kept).

set -euo pipefail

VERSION="${OO_VERSION:-latest}"
PORT="${OO_PORT:-5080}"

usage() {
  echo "Usage: sudo $0 [--version X.Y.Z|latest] [--port N]"
  echo "  -v, --version   OpenObserve version (default: latest)"
  echo "  -p, --port      HTTP port to listen on (default: 5080)"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) VERSION="${2:-}"; shift 2 ;;
    -p|--port)    PORT="${2:-}"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# ---- checks ---------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "Run as root (use sudo)." >&2; exit 1; }

if [[ -r /etc/os-release ]]; then
  # Read without sourcing: os-release defines its own VERSION variable.
  OS_ID="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
  if [[ "$OS_ID" != "ubuntu" ]]; then
    echo "Warning: this script targets Ubuntu 24.04 (found ID=${OS_ID:-unknown})." >&2
  fi
fi

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
  || { echo "Invalid port: $PORT" >&2; exit 1; }

case "$(uname -m)" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

BIN=/usr/local/bin/openobserve
DATA_DIR=/var/lib/openobserve
ENV_FILE=/etc/openobserve.env
SERVICE=/etc/systemd/system/openobserve.service

# If the port is held by something other than our own service, stop early.
if ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
  if ! systemctl is-active --quiet openobserve; then
    echo "Port ${PORT} is already in use by another process." >&2
    exit 1
  fi
fi

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates tar openssl >/dev/null

# ---- resolve version -------------------------------------------------------
if [[ "$VERSION" == "latest" ]]; then
  VERSION="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    https://github.com/openobserve/openobserve/releases/latest | sed 's#.*/tag/v##')"
  [[ -n "$VERSION" ]] || { echo "Could not resolve latest version." >&2; exit 1; }
fi
VERSION="${VERSION#v}"

echo "==> Installing OpenObserve v${VERSION} (${ARCH}) on port ${PORT}"

# ---- download & install binary --------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/openobserve/openobserve/releases/download/v${VERSION}/openobserve-v${VERSION}-linux-${ARCH}.tar.gz"

curl -fSL --retry 3 -o "$TMP/oo.tar.gz" "$URL" \
  || { echo "Download failed. Check that version v${VERSION} exists: $URL" >&2; exit 1; }
tar -xzf "$TMP/oo.tar.gz" -C "$TMP" openobserve

systemctl stop openobserve 2>/dev/null || true
install -m 0755 "$TMP/openobserve" "$BIN"

# ---- user & directories ----------------------------------------------------
id openobserve &>/dev/null || \
  useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin openobserve
mkdir -p "$DATA_DIR"
chown -R openobserve:openobserve "$DATA_DIR"
chmod 750 "$DATA_DIR"

# ---- config (credentials generated once, kept on re-run) -------------------
GENERATED_PASS=""
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  ROOT_EMAIL="${ZO_ROOT_USER_EMAIL}"
  ROOT_PASS="${ZO_ROOT_USER_PASSWORD}"
else
  ROOT_EMAIL="admin@openobserve.local"
  ROOT_PASS="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)"
  GENERATED_PASS="$ROOT_PASS"
fi

cat > "$ENV_FILE" <<EOF
ZO_ROOT_USER_EMAIL=${ROOT_EMAIL}
ZO_ROOT_USER_PASSWORD=${ROOT_PASS}
ZO_HTTP_PORT=${PORT}
ZO_HTTP_ADDR=0.0.0.0
ZO_DATA_DIR=${DATA_DIR}
EOF
chown root:openobserve "$ENV_FILE"
chmod 640 "$ENV_FILE"

# ---- systemd ---------------------------------------------------------------
cat > "$SERVICE" <<EOF
[Unit]
Description=OpenObserve
After=network-online.target
Wants=network-online.target

[Service]
User=openobserve
Group=openobserve
EnvironmentFile=${ENV_FILE}
ExecStart=${BIN}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
WorkingDirectory=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now openobserve

# ---- verify ----------------------------------------------------------------
echo -n "==> Waiting for OpenObserve"
for _ in $(seq 1 30); do
  if curl -fs "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    echo " ... up"
    OK=1; break
  fi
  echo -n "."; sleep 1
done
if [[ -z "${OK:-}" ]]; then
  echo
  echo "Service did not become healthy. Check: journalctl -u openobserve -e" >&2
  exit 1
fi

echo
echo "OpenObserve v${VERSION} installed."
echo "  URL:      http://<server-ip>:${PORT}"
echo "  Email:    ${ROOT_EMAIL}"
if [[ -n "$GENERATED_PASS" ]]; then
  echo "  Password: ${GENERATED_PASS}   (also in ${ENV_FILE})"
else
  echo "  Password: unchanged (see ${ENV_FILE})"
fi
echo "  Data:     ${DATA_DIR}"
echo "  Logs:     journalctl -u openobserve -f"
