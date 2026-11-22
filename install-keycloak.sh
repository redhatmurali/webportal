#!/usr/bin/env bash
#
# Keycloak installer for Ubuntu 24.04
#
# Usage:
#   sudo ./install-keycloak.sh --version 26.0.7 --port 8080
#   sudo ./install-keycloak.sh -v 26.0.7 -p 8080
#   sudo KC_VER=26.0.7 KC_PORT=8080 ./install-keycloak.sh
#
# Only two inputs: version and port. Everything else is automatic.
# Re-running with a different version/port upgrades/reconfigures in place
# (data and admin credentials are kept).
#
# Note: Keycloak 24 and newer need Java 21 (installed here). The bootstrap
# admin variables used below are for Keycloak 26+.

set -euo pipefail

KC_VERSION="${KC_VER:-latest}"
PORT="${KC_PORT:-8080}"

usage() {
  echo "Usage: sudo $0 [--version X.Y.Z|latest] [--port N]"
  echo "  -v, --version   Keycloak version (default: latest)"
  echo "  -p, --port      HTTP port to listen on (default: 8080)"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) KC_VERSION="${2:-}"; shift 2 ;;
    -p|--port)    PORT="${2:-}"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# ---- checks ---------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "Run as root (use sudo)." >&2; exit 1; }

if [[ -r /etc/os-release ]]; then
  OS_ID="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
  [[ "$OS_ID" == "ubuntu" ]] || \
    echo "Warning: this script targets Ubuntu 24.04 (found ID=${OS_ID:-unknown})." >&2
fi

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
  || { echo "Invalid port: $PORT" >&2; exit 1; }

INSTALL_ROOT=/opt
LINK=/opt/keycloak
DATA_DIR=/var/lib/keycloak
ENV_FILE=/etc/keycloak.env
SERVICE=/etc/systemd/system/keycloak.service

# If the port is held by something other than our own service, stop early.
if ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
  if ! systemctl is-active --quiet keycloak; then
    echo "Port ${PORT} is already in use by another process." >&2
    exit 1
  fi
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates tar openssl openjdk-21-jre-headless >/dev/null

# ---- resolve version -------------------------------------------------------
if [[ "$KC_VERSION" == "latest" ]]; then
  KC_VERSION="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    https://github.com/keycloak/keycloak/releases/latest | sed 's#.*/tag/##')"
  [[ -n "$KC_VERSION" ]] || { echo "Could not resolve latest version." >&2; exit 1; }
fi
KC_VERSION="${KC_VERSION#v}"

echo "==> Installing Keycloak ${KC_VERSION} on port ${PORT}"

# ---- user & directories ----------------------------------------------------
id keycloak &>/dev/null || \
  useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin keycloak
mkdir -p "$DATA_DIR/data"
chown -R keycloak:keycloak "$DATA_DIR"

# ---- download & extract ----------------------------------------------------
TARGET="${INSTALL_ROOT}/keycloak-${KC_VERSION}"
if [[ ! -d "$TARGET" ]]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  URL="https://github.com/keycloak/keycloak/releases/download/${KC_VERSION}/keycloak-${KC_VERSION}.tar.gz"
  curl -fSL --retry 3 -o "$TMP/kc.tar.gz" "$URL" \
    || { echo "Download failed. Check that version ${KC_VERSION} exists: $URL" >&2; exit 1; }
  tar -xzf "$TMP/kc.tar.gz" -C "$INSTALL_ROOT"
fi

systemctl stop keycloak 2>/dev/null || true

# Keep the embedded database outside the install dir so upgrades keep data.
if [[ -d "$TARGET/data" && ! -L "$TARGET/data" ]]; then
  cp -an "$TARGET/data/." "$DATA_DIR/data/" 2>/dev/null || true
  rm -rf "$TARGET/data"
fi
ln -sfn "$DATA_DIR/data" "$TARGET/data"
ln -sfn "$TARGET" "$LINK"
chown -R keycloak:keycloak "$TARGET"
chown -h keycloak:keycloak "$LINK"

# ---- config (credentials generated once, kept on re-run) -------------------
GENERATED_PASS=""
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  ADMIN_USER="${KC_BOOTSTRAP_ADMIN_USERNAME}"
  ADMIN_PASS="${KC_BOOTSTRAP_ADMIN_PASSWORD}"
else
  ADMIN_USER="admin"
  ADMIN_PASS="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)"
  GENERATED_PASS="$ADMIN_PASS"
fi

cat > "$ENV_FILE" <<EOF
KC_BOOTSTRAP_ADMIN_USERNAME=${ADMIN_USER}
KC_BOOTSTRAP_ADMIN_PASSWORD=${ADMIN_PASS}
KC_HTTP_ENABLED=true
KC_HTTP_PORT=${PORT}
KC_HOSTNAME_STRICT=false
KC_PROXY_HEADERS=xforwarded
KC_DB=dev-file
EOF
chown root:keycloak "$ENV_FILE"
chmod 640 "$ENV_FILE"

# ---- build (optimised start) ----------------------------------------------
echo "==> Building Keycloak"
sudo -u keycloak bash -c "set -a; . '$ENV_FILE'; set +a; '$LINK/bin/kc.sh' build" >/dev/null

# ---- systemd ---------------------------------------------------------------
cat > "$SERVICE" <<EOF
[Unit]
Description=Keycloak
After=network-online.target
Wants=network-online.target

[Service]
User=keycloak
Group=keycloak
EnvironmentFile=${ENV_FILE}
ExecStart=${LINK}/bin/kc.sh start --optimized
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
WorkingDirectory=${LINK}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now keycloak

# ---- verify ----------------------------------------------------------------
echo -n "==> Waiting for Keycloak"
OK=""
for _ in $(seq 1 90); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" || true)"
  if [[ "$CODE" =~ ^(200|301|302|303)$ ]]; then
    echo " ... up"
    OK=1; break
  fi
  echo -n "."; sleep 2
done
if [[ -z "$OK" ]]; then
  echo
  echo "Service did not become ready. Check: journalctl -u keycloak -e" >&2
  exit 1
fi

echo
echo "Keycloak ${KC_VERSION} installed."
echo "  URL:      http://<server-ip>:${PORT}"
echo "  Admin:    ${ADMIN_USER}"
if [[ -n "$GENERATED_PASS" ]]; then
  echo "  Password: ${GENERATED_PASS}   (also in ${ENV_FILE})"
else
  echo "  Password: unchanged (see ${ENV_FILE})"
fi
echo "  Data:     ${DATA_DIR}/data (embedded H2 database)"
echo "  Logs:     journalctl -u keycloak -f"
