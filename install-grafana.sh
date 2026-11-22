#!/usr/bin/env bash
#
# Grafana (OSS) installer for Ubuntu 24.04
# - Choose the PORT and the VERSION during installation
# - Installs from the official Grafana APT repository (systemd service included)
# - Listens on all interfaces on the chosen port
#
# Interactive:      sudo bash install-grafana.sh
# Non-interactive:  sudo bash install-grafana.sh -p 3001 -v 12.2.0 -y
#
set -euo pipefail

# ---------- defaults (prefixed names avoid clashes with system variables) ----------
GRAFANA_PORT="3000"
GRAFANA_VERSION=""            # empty = latest available
ASSUME_YES="no"

ENV_FILE="/etc/default/grafana-server"
KEYRING="/etc/apt/keyrings/grafana.gpg"
APT_LIST="/etc/apt/sources.list.d/grafana.list"

# ---------- helpers ----------
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m==> %s\033[0m\n' "$*"; }
die()   { red "ERROR: $*"; exit 1; }

usage() {
  cat <<EOF
Usage: sudo bash $0 [options]

  -p PORT      Port Grafana listens on (default: 3000, range 1024-65535)
  -v VERSION   Grafana version, e.g. 12.2.0 (default: latest)
  -y           Non-interactive: use defaults / given flags, no prompts
  -h           Show this help
EOF
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1024 && $1 <= 65535 )); }
port_in_use() { ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; }
# busy by something other than Grafana itself (re-install on the same port is fine)
port_busy_by_other() {
  port_in_use "$1" || return 1
  ! ss -H -ltnp "sport = :$1" 2>/dev/null | grep -q grafana
}

# ---------- parse args ----------
while getopts ":p:v:yh" opt; do
  case "$opt" in
    p) GRAFANA_PORT="$OPTARG" ;;
    v) GRAFANA_VERSION="${OPTARG#v}" ;;
    y) ASSUME_YES="yes" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

OS_ID="$(. /etc/os-release && echo "${ID:-unknown}")"
OS_NAME="$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
if [[ "$OS_ID" != "ubuntu" ]]; then
  red "Warning: this script targets Ubuntu 24.04 (detected: ${OS_NAME})."
fi

valid_port "$GRAFANA_PORT" || die "Invalid port: $GRAFANA_PORT (use 1024-65535)"

# ---------- prerequisites + Grafana APT repo ----------
info "Installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl gnupg ca-certificates apt-transport-https iproute2 >/dev/null

info "Adding the official Grafana APT repository"
mkdir -p /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o "$KEYRING" \
  || die "Could not download the Grafana repository key. Check network access."
chmod 644 "$KEYRING"
echo "deb [signed-by=${KEYRING}] https://apt.grafana.com stable main" > "$APT_LIST"
apt-get update -qq

# ---------- list available versions ----------
mapfile -t AVAILABLE < <(apt-cache madison grafana | awk -F'|' '{gsub(/ /,"",$2); print $2}' | sort -Vru)
(( ${#AVAILABLE[@]} > 0 )) || die "No Grafana versions found in the repository."

# match "12.2.0" (or "12.2.0-xxxx") against the available package versions
resolve_version() {
  local want="$1" v
  for v in "${AVAILABLE[@]}"; do
    if [[ "$v" == "$want" || "$v" == "$want"-* ]]; then echo "$v"; return 0; fi
  done
  return 1
}

# ---------- interactive prompts ----------
if [[ "$ASSUME_YES" != "yes" ]]; then
  echo
  while true; do
    read -rp "Port for Grafana [${GRAFANA_PORT}]: " in_port
    in_port="${in_port:-$GRAFANA_PORT}"
    if valid_port "$in_port"; then GRAFANA_PORT="$in_port"; break; fi
    red "Invalid port (use 1024-65535)."
  done

  echo
  echo "Latest available Grafana versions:"
  printf '   %s\n' "${AVAILABLE[@]:0:10}"
  while true; do
    read -rp "Version (e.g. 12.2.0, or press Enter for latest) [${GRAFANA_VERSION:-latest}]: " in_ver
    in_ver="${in_ver:-${GRAFANA_VERSION:-latest}}"
    in_ver="${in_ver#v}"
    if [[ "$in_ver" == "latest" ]]; then GRAFANA_VERSION=""; break; fi
    if resolve_version "$in_ver" >/dev/null; then GRAFANA_VERSION="$in_ver"; break; fi
    red "Version '$in_ver' is not available in the repository."
  done
fi

# resolve final package version
if [[ -z "$GRAFANA_VERSION" ]]; then
  PKG_VERSION="${AVAILABLE[0]}"
else
  PKG_VERSION="$(resolve_version "$GRAFANA_VERSION")" \
    || die "Version '$GRAFANA_VERSION' not found. Available (newest first): ${AVAILABLE[*]:0:10}"
fi

# ---------- port conflict check ----------
if port_busy_by_other "$GRAFANA_PORT"; then
  red "Port $GRAFANA_PORT is already in use by:"
  ss -ltnp "sport = :$GRAFANA_PORT" || true
  [[ "$ASSUME_YES" == "yes" ]] && die "Choose another port with -p."
  while true; do
    read -rp "Enter a different port: " in_port
    if valid_port "$in_port" && ! port_busy_by_other "$in_port"; then GRAFANA_PORT="$in_port"; break; fi
    red "Invalid or busy port."
  done
fi

# ---------- install ----------
info "Installing Grafana ${PKG_VERSION}"
apt-get install -y -qq --allow-downgrades "grafana=${PKG_VERSION}" >/dev/null \
  || die "Package installation failed."

# keep a deliberately chosen version from being upgraded by unattended upgrades
if [[ -n "$GRAFANA_VERSION" ]]; then
  apt-mark hold grafana >/dev/null
  info "Version pinned (apt-mark hold). Release it later with: apt-mark unhold grafana"
else
  apt-mark unhold grafana >/dev/null 2>&1 || true
fi

# ---------- set the port ----------
# /etc/default/grafana-server is loaded by the systemd unit; GF_* variables override grafana.ini
info "Setting Grafana port to ${GRAFANA_PORT}"
if [[ ! -f "$ENV_FILE" ]]; then
  touch "$ENV_FILE"
  chown root:grafana "$ENV_FILE"
  chmod 640 "$ENV_FILE"
fi
if grep -q '^GF_SERVER_HTTP_PORT=' "$ENV_FILE"; then
  sed -i "s|^GF_SERVER_HTTP_PORT=.*|GF_SERVER_HTTP_PORT=${GRAFANA_PORT}|" "$ENV_FILE"
else
  echo "GF_SERVER_HTTP_PORT=${GRAFANA_PORT}" >> "$ENV_FILE"
fi

# ---------- start ----------
systemctl daemon-reload
systemctl enable grafana-server >/dev/null 2>&1
systemctl restart grafana-server

# ---------- verify ----------
info "Waiting for Grafana to become ready"
ok="no"
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${GRAFANA_PORT}/api/health" >/dev/null 2>&1; then ok="yes"; break; fi
  sleep 1
done

echo
if [[ "$ok" == "yes" ]]; then
  green "Grafana ${PKG_VERSION} is running on port ${GRAFANA_PORT}."
  echo "  URL:       http://<your-server-ip>:${GRAFANA_PORT}"
  echo "  Login:     admin / admin   (you will be asked to change the password)"
  echo "  Config:    /etc/grafana/grafana.ini"
  echo "  Port set:  ${ENV_FILE}  (GF_SERVER_HTTP_PORT=${GRAFANA_PORT})"
  echo "  Service:   systemctl status grafana-server | journalctl -u grafana-server -f"
  echo
  echo "To change the port later: edit GF_SERVER_HTTP_PORT in ${ENV_FILE},"
  echo "then: systemctl restart grafana-server"
else
  red "Grafana did not become ready. Recent logs:"
  journalctl -u grafana-server -n 30 --no-pager || true
  exit 1
fi
