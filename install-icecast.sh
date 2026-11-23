#!/usr/bin/env bash
#===============================================================================
# Icecast installer for Ubuntu 24.04 - built from source, NO Docker/containers.
# (Ubuntu 24.04's apt only has Icecast 2.4.4, so 2.5.x must be compiled.)
#
# Usage:
#   sudo bash install-icecast.sh --version 2.5.0 --port 8000
#   sudo bash install-icecast.sh -v latest -p 8000
#   sudo IC_INSTALL_VERSION=2.5.0 IC_INSTALL_PORT=8000 bash install-icecast.sh
#
#   version = Icecast release (e.g. 2.5.0, 2.4.4) - "latest" = newest release
#   port    = listen port (default 8000)
#
# CREDENTIALS NEVER CHANGE:
#   admin / source / relay passwords are created ONCE in
#   /etc/icecast/credentials.env and reused on every later run (upgrade, port
#   change, re-run). The config file is regenerated from them each time.
#   To choose your own, export IC_ADMIN_PASSWORD / IC_SOURCE_PASSWORD /
#   IC_RELAY_PASSWORD before the FIRST install only.
#===============================================================================
set -euo pipefail

IC_VERSION="${IC_INSTALL_VERSION:-latest}"
PORT="${IC_INSTALL_PORT:-8000}"
LIBIGLOO_VERSION="0.9.5"           # needed by Icecast 2.5.x

usage() {
  echo "Usage: sudo bash $0 [--version X.Y.Z|latest] [--port N]"
  echo "  -v, --version   Icecast version (default: latest)"
  echo "  -p, --port      Listen port (default: 8000)"
  exit "${1:-0}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) IC_VERSION="${2:-}"; shift 2 ;;
    -p|--port)    PORT="${2:-}"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

CONF_DIR=/etc/icecast
CONF_FILE="${CONF_DIR}/icecast.xml"
CRED_FILE="${CONF_DIR}/credentials.env"
LOG_DIR=/var/log/icecast
SHARE_DIR=/usr/local/share/icecast
SERVICE=/etc/systemd/system/icecast.service
BASE=https://downloads.xiph.org/releases

log() { echo -e "\e[1;32m[Icecast]\e[0m $*"; }
err() { echo -e "\e[1;31m[ERR ]\e[0m $*" >&2; }

[[ $EUID -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
  || { err "Invalid port: $PORT"; exit 1; }
[[ -n "$IC_VERSION" ]] || { err "Version cannot be empty."; exit 1; }
IC_VERSION="${IC_VERSION#v}"

if [[ -r /etc/os-release ]]; then
  OS_ID="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
  [[ "$OS_ID" == "ubuntu" ]] || echo "Warning: targets Ubuntu 24.04 (found ID=${OS_ID:-unknown})." >&2
fi

if ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
  systemctl is-active --quiet icecast || { err "Port ${PORT} is already in use by another process."; exit 1; }
fi

export DEBIAN_FRONTEND=noninteractive

#--- 1. Build dependencies ------------------------------------------------------
log "Installing build dependencies..."
apt-get update -qq
apt-get install -y -qq build-essential pkg-config curl ca-certificates openssl \
  libxml2-dev libxslt1-dev libcurl4-openssl-dev libssl-dev libvorbis-dev \
  libogg-dev libtheora-dev libspeex-dev librhash-dev libmaxminddb-dev >/dev/null

#--- 2. Resolve version ---------------------------------------------------------
if [[ "$IC_VERSION" == "latest" ]]; then
  IC_VERSION="$(curl -fsS "${BASE}/icecast/" \
    | grep -oE 'icecast-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' | sed 's/^icecast-//; s/\.tar\.gz$//' \
    | sort -V | uniq | tail -n1 || true)"
  [[ -n "$IC_VERSION" ]] || { err "Could not resolve latest version; pass --version."; exit 1; }
fi
log "Icecast ${IC_VERSION} on port ${PORT}"

#--- 3. libigloo (only for Icecast 2.5+) ----------------------------------------
NEED_IGLOO=""
dpkg --compare-versions "$IC_VERSION" ge 2.4.99 && NEED_IGLOO=1
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

if [[ -n "$NEED_IGLOO" ]] && ! pkg-config --atleast-version="${LIBIGLOO_VERSION}" igloo 2>/dev/null; then
  log "Building libigloo ${LIBIGLOO_VERSION}..."
  WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
  curl -fSL --retry 3 -o "$WORK/igloo.tar.gz" "${BASE}/igloo/libigloo-${LIBIGLOO_VERSION}.tar.gz" \
    || { err "Download failed: ${BASE}/igloo/libigloo-${LIBIGLOO_VERSION}.tar.gz"; exit 1; }
  tar -xzf "$WORK/igloo.tar.gz" -C "$WORK"
  ( cd "$WORK"/libigloo-* && ./configure --prefix=/usr/local >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null )
  ldconfig
  rm -rf "$WORK"; trap - EXIT
fi

#--- 4. Build Icecast (skipped if this version is already installed) ------------
CUR="$(/usr/local/bin/icecast -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
systemctl stop icecast 2>/dev/null || true
if [[ "$CUR" == "$IC_VERSION" ]]; then
  log "Icecast ${IC_VERSION} already installed - skipping build"
else
  log "Building Icecast ${IC_VERSION} (a few minutes)..."
  WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
  curl -fSL --retry 3 -o "$WORK/icecast.tar.gz" "${BASE}/icecast/icecast-${IC_VERSION}.tar.gz" \
    || { err "Download failed. Check version ${IC_VERSION} exists: ${BASE}/icecast/"; exit 1; }
  tar -xzf "$WORK/icecast.tar.gz" -C "$WORK"
  ( cd "$WORK"/icecast-* \
    && ./configure --prefix=/usr/local --sysconfdir="${CONF_DIR}" --localstatedir=/var >/dev/null \
    && make -j"$(nproc)" >/dev/null && make install >/dev/null )
  rm -rf "$WORK"; trap - EXIT
fi
[[ -x /usr/local/bin/icecast ]] || { err "Icecast binary missing after install."; exit 1; }
[[ -d "${SHARE_DIR}/web" ]] || { err "Web files not found in ${SHARE_DIR}."; exit 1; }

#--- 5. User & directories ------------------------------------------------------
id icecast &>/dev/null || useradd --system --home-dir /var/lib/icecast --shell /usr/sbin/nologin icecast
mkdir -p "$CONF_DIR" "$LOG_DIR"
chown -R icecast:icecast "$LOG_DIR"
chmod 700 "$CONF_DIR"

#--- 6. Credentials (created once, never changed) ------------------------------
NEW_INSTALL=""
if [[ -f "$CRED_FILE" ]]; then
  log "Existing credentials found in ${CRED_FILE} - keeping them unchanged"
else
  NEW_INSTALL=1
  umask 077
  cat > "$CRED_FILE" <<EOF
ADMIN_USER=admin
ADMIN_PASS=${IC_ADMIN_PASSWORD:-$(openssl rand -hex 12)}
SOURCE_PASS=${IC_SOURCE_PASSWORD:-$(openssl rand -hex 12)}
RELAY_PASS=${IC_RELAY_PASSWORD:-$(openssl rand -hex 12)}
EOF
  chmod 600 "$CRED_FILE"
  umask 022
fi
cred() { sed -n "s/^$1=//p" "$CRED_FILE" | head -n1; }
ADMIN_USER="$(cred ADMIN_USER)"; ADMIN_PASS="$(cred ADMIN_PASS)"
SOURCE_PASS="$(cred SOURCE_PASS)"; RELAY_PASS="$(cred RELAY_PASS)"
[[ -n "$ADMIN_PASS" && -n "$SOURCE_PASS" && -n "$RELAY_PASS" ]] \
  || { err "Empty credential in ${CRED_FILE}."; exit 1; }

SERVER_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

#--- 7. icecast.xml (regenerated from credentials + port) ----------------------
# Keep a custom hostname if one was already set.
HOSTNAME_VAL="$SERVER_IP"
if [[ -f "$CONF_FILE" ]]; then
  OLDH="$(sed -n 's#.*<hostname>\(.*\)</hostname>.*#\1#p' "$CONF_FILE" | head -n1)"
  [[ -n "$OLDH" ]] && HOSTNAME_VAL="$OLDH"
fi

cat > "$CONF_FILE" <<EOF
<icecast>
    <location>Earth</location>
    <admin>admin@localhost</admin>

    <limits>
        <clients>200</clients>
        <sources>10</sources>
        <queue-size>524288</queue-size>
        <client-timeout>30</client-timeout>
        <header-timeout>15</header-timeout>
        <source-timeout>10</source-timeout>
        <burst-on-connect>1</burst-on-connect>
        <burst-size>65535</burst-size>
    </limits>

    <authentication>
        <source-password>${SOURCE_PASS}</source-password>
        <relay-password>${RELAY_PASS}</relay-password>
        <admin-user>${ADMIN_USER}</admin-user>
        <admin-password>${ADMIN_PASS}</admin-password>
    </authentication>

    <hostname>${HOSTNAME_VAL}</hostname>

    <listen-socket>
        <port>${PORT}</port>
    </listen-socket>

    <fileserve>1</fileserve>

    <paths>
        <basedir>${SHARE_DIR}</basedir>
        <logdir>${LOG_DIR}</logdir>
        <webroot>${SHARE_DIR}/web</webroot>
        <adminroot>${SHARE_DIR}/admin</adminroot>
        <pidfile>/run/icecast/icecast.pid</pidfile>
        <alias source="/" destination="/status.xsl"/>
    </paths>

    <logging>
        <accesslog>access.log</accesslog>
        <errorlog>error.log</errorlog>
        <loglevel>3</loglevel>
        <logsize>10000</logsize>
    </logging>

    <security>
        <chroot>0</chroot>
    </security>
</icecast>
EOF
chown root:icecast "$CONF_FILE" "$CRED_FILE"
chmod 640 "$CONF_FILE" "$CRED_FILE"
chmod 750 "$CONF_DIR"

#--- 8. systemd -----------------------------------------------------------------
cat > "$SERVICE" <<EOF
[Unit]
Description=Icecast streaming server
After=network-online.target
Wants=network-online.target

[Service]
User=icecast
Group=icecast
RuntimeDirectory=icecast
ExecStart=/usr/local/bin/icecast -c ${CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now icecast
systemctl restart icecast

#--- 9. Health ------------------------------------------------------------------
log "Waiting for Icecast on :${PORT}..."
OK=""
for _ in $(seq 1 20); do
  if curl -fs "http://127.0.0.1:${PORT}/status-json.xsl" >/dev/null 2>&1; then OK=1; break; fi
  sleep 1
done
[[ -n "$OK" ]] || { err "No response. Check: journalctl -u icecast -e  and  ${LOG_DIR}/error.log"; exit 1; }

echo
echo "========== Icecast ${IC_VERSION} RUNNING =========="
echo "Status page : http://${SERVER_IP}:${PORT}/"
echo "Admin       : http://${SERVER_IP}:${PORT}/admin/"
echo "  user      : ${ADMIN_USER}"
echo "  password  : ${ADMIN_PASS}"
echo "Source pass : ${SOURCE_PASS}   (for BUTT / OBS / ffmpeg / Liquidsoap; user: source)"
echo "Relay pass  : ${RELAY_PASS}"
if [[ -n "$NEW_INSTALL" ]]; then
  echo "(generated now and saved in ${CRED_FILE}; they will never change)"
else
  echo "(unchanged, from ${CRED_FILE})"
fi
echo "Config      : ${CONF_FILE}"
echo "Logs        : ${LOG_DIR}/   journalctl -u icecast -f"
echo "Hostname    : ${HOSTNAME_VAL}  (edit <hostname> in the config for your domain; it is kept on re-runs)"
echo "=================================================="
