#!/usr/bin/env bash
#===============================================================================
# WAHA (WhatsApp HTTP API) installer - Ubuntu 24.04, NO Docker / containers.
# Builds WAHA Core from source with an ISOLATED Node 24 (nvm, under the 'waha'
# user only). System Node (n8n, etc.) is never touched.
#
# Usage:
#   sudo bash install-waha.sh --version core --port 3008
#   sudo bash install-waha.sh -v 2025.10.1 -p 3008
#   sudo WAHA_INSTALL_VERSION=core WAHA_INSTALL_PORT=3008 bash install-waha.sh
#
#   version = git branch or tag of github.com/devlikeapro/waha (default: core)
#   port    = HTTP port (default: 3000)
#
# CREDENTIALS NEVER CHANGE:
#   API key / dashboard / swagger logins are created ONCE in /opt/waha/.env and
#   never overwritten by later runs (upgrade, port change, re-run). If an older
#   /etc/waha/waha.env exists, its values are reused for the first .env.
#===============================================================================
set -euo pipefail

#--- Inputs --------------------------------------------------------------------
WAHA_REF="${WAHA_INSTALL_VERSION:-core}"
WAHA_PORT="${WAHA_INSTALL_PORT:-3000}"

usage() {
  echo "Usage: sudo bash $0 [--version BRANCH|TAG] [--port N]"
  echo "  -v, --version   WAHA git branch/tag (default: core)"
  echo "  -p, --port      HTTP port (default: 3000)"
  exit "${1:-0}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) WAHA_REF="${2:-}"; shift 2 ;;
    -p|--port)    WAHA_PORT="${2:-}"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

#--- Fixed settings ------------------------------------------------------------
WAHA_USER="waha"
WAHA_DIR="/opt/waha"
WAHA_ENGINE="NOWEB"
NODE_MAJOR="24"
TZ_REGION="Asia/Kolkata"
NVM_VERSION="v0.40.1"
OLD_CRED="/etc/waha/waha.env"      # written by the earlier installer, if any

log() { echo -e "\e[1;32m[WAHA]\e[0m $*"; }
err() { echo -e "\e[1;31m[ERR ]\e[0m $*" >&2; }

[[ $EUID -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }
[[ "$WAHA_PORT" =~ ^[0-9]+$ ]] && (( WAHA_PORT >= 1 && WAHA_PORT <= 65535 )) \
  || { err "Invalid port: $WAHA_PORT"; exit 1; }
[[ -n "$WAHA_REF" ]] || { err "Version cannot be empty."; exit 1; }
WAHA_REF="${WAHA_REF#v}"
[[ "$WAHA_REF" == "latest" ]] && WAHA_REF="core"
export DEBIAN_FRONTEND=noninteractive

if ss -ltn "sport = :${WAHA_PORT}" 2>/dev/null | grep -q LISTEN; then
  systemctl is-active --quiet waha || { err "Port ${WAHA_PORT} is already in use by another process."; exit 1; }
fi

SYS_NODE="$(command -v node >/dev/null 2>&1 && node -v || echo none)"
log "System Node (left untouched): ${SYS_NODE}"
log "Installing WAHA '${WAHA_REF}' on port ${WAHA_PORT}"

#--- 1. Base packages ----------------------------------------------------------
log "Installing prerequisites..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git build-essential \
  python3 openssl ffmpeg jq unzip wget >/dev/null

#--- 2. Service user -----------------------------------------------------------
id -u "${WAHA_USER}" >/dev/null 2>&1 || useradd -r -m -d "${WAHA_DIR}" -s /bin/bash "${WAHA_USER}"
# An earlier installer created this user with nologin; nvm needs a real shell.
usermod -s /bin/bash "${WAHA_USER}"
mkdir -p "${WAHA_DIR}"
chown "${WAHA_USER}:${WAHA_USER}" "${WAHA_DIR}"

#--- 3. Isolated Node 24 via nvm ----------------------------------------------
systemctl stop waha 2>/dev/null || true
log "Installing isolated Node ${NODE_MAJOR} for '${WAHA_USER}' via nvm..."
sudo -u "${WAHA_USER}" -H bash -c '
  set -e
  export NVM_DIR="$HOME/.nvm"
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/'"${NVM_VERSION}"'/install.sh | bash >/dev/null 2>&1
  fi
  . "$NVM_DIR/nvm.sh"
  nvm install '"${NODE_MAJOR}"' >/dev/null 2>&1
  nvm alias default '"${NODE_MAJOR}"' >/dev/null 2>&1
  corepack enable >/dev/null 2>&1 || npm install -g yarn >/dev/null 2>&1
'
NODE_BIN="$(sudo -u "${WAHA_USER}" -H bash -c '. "$HOME/.nvm/nvm.sh"; command -v node')"
[[ -n "${NODE_BIN}" ]] || { err "Isolated Node install failed."; exit 1; }
log "Isolated node: ${NODE_BIN} ($(sudo -u "${WAHA_USER}" -H bash -c '. "$HOME/.nvm/nvm.sh"; node -v'))"

waha_run() { sudo -u "${WAHA_USER}" -H bash -c '. "$HOME/.nvm/nvm.sh"; cd "'"${WAHA_DIR}"'"; '"$*"; }

#--- 4. Source (branch or tag) -------------------------------------------------
if [[ -d "${WAHA_DIR}/.git" ]]; then
  log "Existing checkout - switching to '${WAHA_REF}'..."
  waha_run "git fetch --depth 1 origin '${WAHA_REF}' && git checkout -f FETCH_HEAD" \
    || { err "Branch/tag '${WAHA_REF}' not found. List: git ls-remote --heads --tags https://github.com/devlikeapro/waha"; exit 1; }
else
  log "Cloning WAHA (${WAHA_REF})..."
  find "${WAHA_DIR}" -maxdepth 1 -mindepth 1 ! -name '.nvm' ! -name '.env' ! -name '.sessions' ! -name '.media' -exec rm -rf {} +
  sudo -u "${WAHA_USER}" -H git clone --depth 1 --branch "${WAHA_REF}" \
    https://github.com/devlikeapro/waha "${WAHA_DIR}/repo" \
    || { err "Branch/tag '${WAHA_REF}' not found."; exit 1; }
  shopt -s dotglob
  mv "${WAHA_DIR}/repo/"* "${WAHA_DIR}/"
  shopt -u dotglob
  rmdir "${WAHA_DIR}/repo"
fi
mkdir -p "${WAHA_DIR}/.sessions" "${WAHA_DIR}/.media"
chown -R "${WAHA_USER}:${WAHA_USER}" "${WAHA_DIR}"

#--- 5. Dependencies + build ---------------------------------------------------
log "Installing dependencies (a few minutes)..."
waha_run "COREPACK_ENABLE_DOWNLOAD_PROMPT=0 YARN_ENABLE_IMMUTABLE_INSTALLS=false YARN_HTTP_TIMEOUT=600000 YARN_HTTP_RETRY=5 yarn install --network-timeout 600000"

log "Building (nest build)..."
waha_run "yarn build"
[[ -f "${WAHA_DIR}/dist/main.js" ]] || { err "Build failed - dist/main.js missing."; exit 1; }

#--- 5b. Web Dashboard (pinned revision from waha.config.json) -----------------
log "Fetching Web Dashboard (pinned in waha.config.json)..."
DASH_REPO="$(jq -r '.waha.dashboard.repo // empty' "${WAHA_DIR}/waha.config.json")"
DASH_SHA="$(jq -r '.waha.dashboard.ref // empty' "${WAHA_DIR}/waha.config.json")"
if [[ -z "${DASH_REPO}" || -z "${DASH_SHA}" ]]; then
  err "Dashboard repository/ref missing in waha.config.json."
  exit 1
fi
log "Dashboard: ${DASH_REPO}@${DASH_SHA:0:12}"
TMPZ="$(mktemp -d)"
trap 'rm -rf "${TMPZ}"' EXIT
curl -fL --retry 3 --retry-delay 2 \
  "https://github.com/${DASH_REPO}/archive/${DASH_SHA}.zip" -o "${TMPZ}/dash.zip"
unzip -q "${TMPZ}/dash.zip" -d "${TMPZ}/x"
DASH_INDEX="$(find "${TMPZ}/x" -type f -name index.html -print -quit)"
[[ -n "${DASH_INDEX}" ]] || { err "Dashboard archive contains no index.html."; exit 1; }
DASH_SOURCE="$(dirname "${DASH_INDEX}")"
rm -rf "${WAHA_DIR}/dist/dashboard"
mkdir -p "${WAHA_DIR}/dist/dashboard"
cp -a "${DASH_SOURCE}/." "${WAHA_DIR}/dist/dashboard/"
chown -R "${WAHA_USER}:${WAHA_USER}" "${WAHA_DIR}/dist/dashboard"
test -f "${WAHA_DIR}/dist/dashboard/index.html"
log "Dashboard installed: ${WAHA_DIR}/dist/dashboard/index.html"
rm -rf "${TMPZ}"; trap - EXIT

#--- 6. Environment (credentials created once, never changed) ------------------
ENV_FILE="${WAHA_DIR}/.env"
old_val() { [[ -f "${OLD_CRED}" ]] && sed -n "s/^$1=//p" "${OLD_CRED}" | tail -n 1 || true; }
set_env() {  # set_env KEY VALUE  (always overwrite: non-secret settings)
  if grep -qE "^$1=" "${ENV_FILE}"; then sed -i "s|^$1=.*|$1=$2|" "${ENV_FILE}"
  else printf '%s=%s\n' "$1" "$2" >> "${ENV_FILE}"; fi
}
set_env_default() {  # only add when missing (keeps existing values)
  grep -qE "^$1=" "${ENV_FILE}" || printf '%s=%s\n' "$1" "$2" >> "${ENV_FILE}"
}

NEW_INSTALL=""
if [[ ! -s "${ENV_FILE}" ]]; then
  NEW_INSTALL=1
  log "Creating persistent credentials (one time only)..."
  API_KEY="${WAHA_API_KEY:-$(old_val WAHA_API_KEY)}";            API_KEY="${API_KEY:-$(openssl rand -hex 32)}"
  DASH_USER="${WAHA_USERNAME:-$(old_val WAHA_DASHBOARD_USERNAME)}"; DASH_USER="${DASH_USER:-admin}"
  DASH_PASS="${WAHA_PASSWORD:-$(old_val WAHA_DASHBOARD_PASSWORD)}"; DASH_PASS="${DASH_PASS:-$(openssl rand -hex 16)}"
  : > "${ENV_FILE}"; chmod 600 "${ENV_FILE}"
  set_env WHATSAPP_API_KEY "${API_KEY}"
  set_env WAHA_API_KEY "${API_KEY}"
  set_env WAHA_DASHBOARD_ENABLED "true"
  set_env WAHA_DASHBOARD_USERNAME "${DASH_USER}"
  set_env WAHA_DASHBOARD_PASSWORD "${DASH_PASS}"
  set_env WHATSAPP_SWAGGER_USERNAME "${DASH_USER}"
  set_env WHATSAPP_SWAGGER_PASSWORD "${DASH_PASS}"
else
  log "Existing ${ENV_FILE} found; credentials preserved."
fi

# Non-secret settings (port can change between runs)
set_env PORT "${WAHA_PORT}"
set_env WHATSAPP_API_PORT "${WAHA_PORT}"
set_env TZ "${TZ_REGION}"
set_env_default WHATSAPP_DEFAULT_ENGINE "${WAHA_ENGINE}"
set_env_default WHATSAPP_NOWEB_STORE_ENABLED "true"
set_env_default WHATSAPP_NOWEB_STORE_FULLSYNC "true"
set_env_default WHATSAPP_RESTART_ALL_SESSIONS "true"
set_env_default WAHA_PRINT_QR "false"
set_env_default WAHA_LOG_FORMAT "JSON"
set_env_default WAHA_LOG_LEVEL "info"
set_env_default WHATSAPP_SESSIONS_FOLDER "${WAHA_DIR}/.sessions"
set_env_default WHATSAPP_FILES_FOLDER "${WAHA_DIR}/.media"
set_env_default WHATSAPP_FILES_LIFETIME "180"
chmod 600 "${ENV_FILE}"
chown "${WAHA_USER}:${WAHA_USER}" "${ENV_FILE}"

env_value() { sed -n "s/^$1=//p" "${ENV_FILE}" | tail -n 1; }
API_KEY="$(env_value WHATSAPP_API_KEY)"
DASH_USER="$(env_value WAHA_DASHBOARD_USERNAME)"
DASH_PASS="$(env_value WAHA_DASHBOARD_PASSWORD)"
SWAGGER_USER="$(env_value WHATSAPP_SWAGGER_USERNAME)"
SWAGGER_PASS="$(env_value WHATSAPP_SWAGGER_PASSWORD)"
[[ -n "${API_KEY}" && -n "${DASH_PASS}" && -n "${SWAGGER_PASS}" ]] \
  || { err "A credential is empty in ${ENV_FILE}. Fix the file and re-run."; exit 1; }

#--- 7. systemd ----------------------------------------------------------------
log "Creating systemd service..."
cat > /etc/systemd/system/waha.service <<EOF
[Unit]
Description=WAHA - WhatsApp HTTP API (isolated Node)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${WAHA_USER}
Group=${WAHA_USER}
WorkingDirectory=${WAHA_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${NODE_BIN} ${WAHA_DIR}/dist/main.js
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${WAHA_DIR}
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now waha
systemctl restart waha

#--- 8. Health -----------------------------------------------------------------
log "Waiting for WAHA on :${WAHA_PORT}..."
for i in {1..40}; do
  curl -fs "http://127.0.0.1:${WAHA_PORT}/ping" >/dev/null 2>&1 && break
  sleep 3
  [[ $i -eq 40 ]] && { err "No response in 120s. Check: journalctl -u waha -e"; exit 1; }
done
DCODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WAHA_PORT}/dashboard/" || true)"

#--- 9. Summary ----------------------------------------------------------------
echo
echo "========== WAHA ${WAHA_REF} RUNNING =========="
echo "Dashboard : http://<server-ip>:${WAHA_PORT}/dashboard   (HTTP ${DCODE})"
echo "  user    : ${DASH_USER}"
echo "  pass    : ${DASH_PASS}"
echo "Swagger   : http://<server-ip>:${WAHA_PORT}/"
echo "  user    : ${SWAGGER_USER}"
echo "  pass    : ${SWAGGER_PASS}"
echo "API key   : ${API_KEY}    (header: X-Api-Key)"
if [[ -n "${NEW_INSTALL}" ]]; then
  echo "(generated now and saved in ${ENV_FILE} - they will never change)"
else
  echo "(unchanged, from ${ENV_FILE})"
fi
echo "Engine    : ${WAHA_ENGINE}   Node: $(sudo -u "${WAHA_USER}" -H bash -c '. "$HOME/.nvm/nvm.sh"; node -v')   System Node: ${SYS_NODE} (untouched)"
echo "Logs      : journalctl -u waha -f"
echo "=============================================="
