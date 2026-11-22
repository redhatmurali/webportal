#!/usr/bin/env bash
#
# Semaphore UI installer for Ubuntu 24.04
#
# Usage:
#   sudo ./install-semaphore.sh --version 2.10.35 --port 3000
#   sudo ./install-semaphore.sh -v 2.10.35 -p 3000
#   sudo SEM_VER=2.10.35 SEM_PORT=3000 ./install-semaphore.sh
#
# Only two inputs: version and port. Everything else is automatic.
# Re-running with a different version/port upgrades/reconfigures in place
# (data, secrets and admin credentials are kept).

set -euo pipefail

SEM_VERSION="${SEM_VER:-latest}"
PORT="${SEM_PORT:-3000}"

usage() {
  echo "Usage: sudo $0 [--version X.Y.Z|latest] [--port N]"
  echo "  -v, --version   Semaphore version (default: latest)"
  echo "  -p, --port      HTTP port to listen on (default: 3000)"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) SEM_VERSION="${2:-}"; shift 2 ;;
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

case "$(uname -m)" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

BIN=/usr/local/bin/semaphore
HOME_DIR=/var/lib/semaphore
ENV_FILE=/etc/semaphore.env
SERVICE=/etc/systemd/system/semaphore.service

# If the port is held by something other than our own service, stop early.
if ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
  if ! systemctl is-active --quiet semaphore; then
    echo "Port ${PORT} is already in use by another process." >&2
    exit 1
  fi
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# git/python/ansible are what Semaphore needs to run playbooks.
apt-get install -y -qq curl ca-certificates tar openssl git python3 python3-pip \
  python3-venv ansible sshpass >/dev/null

# ---- resolve version -------------------------------------------------------
if [[ "$SEM_VERSION" == "latest" ]]; then
  SEM_VERSION="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    https://github.com/semaphoreui/semaphore/releases/latest | sed 's#.*/tag/v##')"
  [[ -n "$SEM_VERSION" ]] || { echo "Could not resolve latest version." >&2; exit 1; }
fi
SEM_VERSION="${SEM_VERSION#v}"

echo "==> Installing Semaphore v${SEM_VERSION} (${ARCH}) on port ${PORT}"

# ---- download & install binary --------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/semaphoreui/semaphore/releases/download/v${SEM_VERSION}/semaphore_${SEM_VERSION}_linux_${ARCH}.tar.gz"

curl -fSL --retry 3 -o "$TMP/sem.tar.gz" "$URL" \
  || { echo "Download failed. Check that version v${SEM_VERSION} exists: $URL" >&2; exit 1; }
tar -xzf "$TMP/sem.tar.gz" -C "$TMP"
[[ -f "$TMP/semaphore" ]] || { echo "Archive did not contain a 'semaphore' binary." >&2; exit 1; }

systemctl stop semaphore 2>/dev/null || true
install -m 0755 "$TMP/semaphore" "$BIN"

# ---- user & directories ----------------------------------------------------
id semaphore &>/dev/null || \
  useradd --system --home-dir "$HOME_DIR" --shell /usr/sbin/nologin semaphore
mkdir -p "$HOME_DIR/data" "$HOME_DIR/tmp"
chown -R semaphore:semaphore "$HOME_DIR"
chmod 750 "$HOME_DIR"

# ---- config (secrets generated once, kept on re-run) -----------------------
GENERATED_PASS=""
if [[ -f "$ENV_FILE" ]]; then
  # Keep existing secrets/credentials; only update the port.
  sed -i "s|^SEMAPHORE_PORT=.*|SEMAPHORE_PORT=:${PORT}|" "$ENV_FILE"
else
  ADMIN_PASS="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)"
  GENERATED_PASS="$ADMIN_PASS"
  cat > "$ENV_FILE" <<EOF
SEMAPHORE_DB_DIALECT=bolt
SEMAPHORE_DB_HOST=${HOME_DIR}/data/database.boltdb
SEMAPHORE_PORT=:${PORT}
SEMAPHORE_TMP_PATH=${HOME_DIR}/tmp
SEMAPHORE_COOKIE_HASH=$(openssl rand -base64 32)
SEMAPHORE_COOKIE_ENCRYPTION=$(openssl rand -base64 32)
SEMAPHORE_ACCESS_KEY_ENCRYPTION=$(openssl rand -base64 32)
SEMAPHORE_ADMIN=admin
SEMAPHORE_ADMIN_NAME=Admin
SEMAPHORE_ADMIN_EMAIL=admin@localhost
SEMAPHORE_ADMIN_PASSWORD=${ADMIN_PASS}
EOF
fi
chown root:semaphore "$ENV_FILE"
chmod 640 "$ENV_FILE"

# ---- systemd ---------------------------------------------------------------
cat > "$SERVICE" <<EOF
[Unit]
Description=Semaphore UI
After=network-online.target
Wants=network-online.target

[Service]
User=semaphore
Group=semaphore
EnvironmentFile=${ENV_FILE}
Environment=HOME=${HOME_DIR}
ExecStart=${BIN} server --no-config
Restart=on-failure
RestartSec=5
WorkingDirectory=${HOME_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now semaphore

# ---- verify ----------------------------------------------------------------
echo -n "==> Waiting for Semaphore"
OK=""
for _ in $(seq 1 30); do
  if curl -fs "http://127.0.0.1:${PORT}/api/ping" >/dev/null 2>&1; then
    echo " ... up"
    OK=1; break
  fi
  echo -n "."; sleep 1
done
if [[ -z "$OK" ]]; then
  echo
  echo "Service did not become healthy. Check: journalctl -u semaphore -e" >&2
  exit 1
fi

echo
echo "Semaphore v${SEM_VERSION} installed."
echo "  URL:      http://<server-ip>:${PORT}"
echo "  Admin:    admin"
if [[ -n "$GENERATED_PASS" ]]; then
  echo "  Password: ${GENERATED_PASS}   (also in ${ENV_FILE})"
else
  echo "  Password: unchanged (see ${ENV_FILE})"
fi
echo "  Data:     ${HOME_DIR}/data"
echo "  Logs:     journalctl -u semaphore -f"
