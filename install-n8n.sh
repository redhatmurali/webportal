#!/usr/bin/env bash
#
# n8n installer for Ubuntu 24.04 (npm install + systemd service)
#
# Usage:
#   sudo ./install-n8n.sh --version 1.76.1 --port 5678
#   sudo ./install-n8n.sh -v 1.76.1 -p 5678
#   sudo N8N_INSTALL_VERSION=1.76.1 N8N_INSTALL_PORT=5678 ./install-n8n.sh
#
# Only two inputs: version and port. Everything else is automatic.
# Re-running with a different version/port upgrades/reconfigures in place
# (data and the encryption key are kept).

set -euo pipefail

N8N_VERSION="${N8N_INSTALL_VERSION:-latest}"
PORT="${N8N_INSTALL_PORT:-5678}"

usage() {
  echo "Usage: sudo $0 [--version X.Y.Z|latest] [--port N]"
  echo "  -v, --version   n8n version (default: latest)"
  echo "  -p, --port      HTTP port to listen on (default: 5678)"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) N8N_VERSION="${2:-}"; shift 2 ;;
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

HOME_DIR=/var/lib/n8n
ENV_FILE=/etc/n8n.env
SERVICE=/etc/systemd/system/n8n.service

# If the port is held by something other than our own service, stop early.
if ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
  if ! systemctl is-active --quiet n8n; then
    echo "Port ${PORT} is already in use by another process." >&2
    exit 1
  fi
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates openssl build-essential python3 >/dev/null

# ---- Node.js 22 (Ubuntu's apt nodejs is too old for n8n) -------------------
NODE_MAJOR=0
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
fi
if (( NODE_MAJOR < 22 )); then
  echo "==> Installing Node.js 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi

# ---- resolve version -------------------------------------------------------
if [[ "$N8N_VERSION" == "latest" ]]; then
  N8N_VERSION="$(npm view n8n version)"
  [[ -n "$N8N_VERSION" ]] || { echo "Could not resolve latest version." >&2; exit 1; }
fi
N8N_VERSION="${N8N_VERSION#v}"

echo "==> Installing n8n ${N8N_VERSION} on port ${PORT}"

systemctl stop n8n 2>/dev/null || true
npm install -g "n8n@${N8N_VERSION}" --no-fund --no-audit \
  || { echo "npm install failed. Check that n8n@${N8N_VERSION} exists (npm view n8n versions)." >&2; exit 1; }

N8N_BIN="$(command -v n8n)"
[[ -x "$N8N_BIN" ]] || { echo "n8n binary not found after install." >&2; exit 1; }

# ---- user & directories ----------------------------------------------------
id n8n &>/dev/null || \
  useradd --system --home-dir "$HOME_DIR" --shell /usr/sbin/nologin n8n
mkdir -p "$HOME_DIR"
chown -R n8n:n8n "$HOME_DIR"
chmod 750 "$HOME_DIR"

# ---- config (encryption key generated once, kept on re-run) ----------------
if [[ -f "$ENV_FILE" ]]; then
  sed -i "s|^N8N_PORT=.*|N8N_PORT=${PORT}|" "$ENV_FILE"
else
  cat > "$ENV_FILE" <<EOF
N8N_PORT=${PORT}
N8N_HOST=0.0.0.0
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
N8N_SECURE_COOKIE=false
N8N_DIAGNOSTICS_ENABLED=false
N8N_RUNNERS_ENABLED=true
GENERIC_TIMEZONE=Asia/Kolkata
TZ=Asia/Kolkata
EOF
fi
chown root:n8n "$ENV_FILE"
chmod 640 "$ENV_FILE"

# ---- systemd ---------------------------------------------------------------
cat > "$SERVICE" <<EOF
[Unit]
Description=n8n workflow automation
After=network-online.target
Wants=network-online.target

[Service]
User=n8n
Group=n8n
EnvironmentFile=${ENV_FILE}
Environment=HOME=${HOME_DIR}
Environment=N8N_USER_FOLDER=${HOME_DIR}
ExecStart=${N8N_BIN} start
Restart=on-failure
RestartSec=5
WorkingDirectory=${HOME_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now n8n

# ---- verify ----------------------------------------------------------------
echo -n "==> Waiting for n8n"
OK=""
for _ in $(seq 1 60); do
  if curl -fs "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    echo " ... up"
    OK=1; break
  fi
  echo -n "."; sleep 2
done
if [[ -z "$OK" ]]; then
  echo
  echo "Service did not become healthy. Check: journalctl -u n8n -e" >&2
  exit 1
fi

echo
echo "n8n ${N8N_VERSION} installed."
echo "  URL:      http://<server-ip>:${PORT}   (create the owner account on first visit)"
echo "  Config:   ${ENV_FILE}"
echo "  Data:     ${HOME_DIR}/.n8n"
echo "  Logs:     journalctl -u n8n -f"
echo
echo "Behind HTTPS, set N8N_SECURE_COOKIE=true, N8N_PROTOCOL=https and"
echo "WEBHOOK_URL=https://your-domain/ in ${ENV_FILE}, then: systemctl restart n8n"
