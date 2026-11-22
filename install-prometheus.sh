#!/usr/bin/env bash
#
# Prometheus installer for Ubuntu 24.04
# - Asks for the port and version during installation
# - Listens on all interfaces (0.0.0.0) on the chosen port
# - Installs the official binary release and creates a systemd service
#
# Interactive:      sudo bash install-prometheus.sh
# Non-interactive:  sudo bash install-prometheus.sh -p 9095 -v 3.5.0 -y
#
set -euo pipefail

# ---------- defaults (names are prefixed to avoid clashes with system vars) ----------
PROM_PORT="9090"
PROM_VERSION=""                   # empty = latest release
FALLBACK_VERSION="3.5.0"          # used only if the GitHub lookup fails
RETENTION="15d"
ASSUME_YES="no"
OPEN_FIREWALL="ask"

PROM_USER="prometheus"
CONF_DIR="/etc/prometheus"
DATA_DIR="/var/lib/prometheus"
BIN_DIR="/usr/local/bin"
SERVICE="/etc/systemd/system/prometheus.service"

# ---------- helpers ----------
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m==> %s\033[0m\n' "$*"; }
die()   { red "ERROR: $*"; exit 1; }

usage() {
  cat <<EOF
Usage: sudo bash $0 [options]

  -p PORT      Port Prometheus listens on (default: 9090)
  -v VERSION   Prometheus version, e.g. 3.5.0 (default: latest)
  -r RETENTION Data retention, e.g. 15d, 30d (default: 15d)
  -f           Open the port in UFW if UFW is active
  -y           Non-interactive: use defaults / given flags, no prompts
  -h           Show this help
EOF
}

valid_port()    { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; }
port_in_use()   { ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; }

# ---------- parse args ----------
while getopts ":p:v:r:fyh" opt; do
  case "$opt" in
    p) PROM_PORT="$OPTARG" ;;
    v) PROM_VERSION="${OPTARG#v}" ;;
    r) RETENTION="$OPTARG" ;;
    f) OPEN_FIREWALL="yes" ;;
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

# ---------- prerequisites ----------
info "Installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl tar ca-certificates iproute2 >/dev/null

# ---------- interactive prompts ----------
if [[ "$ASSUME_YES" != "yes" ]]; then
  echo
  while true; do
    read -rp "Port for Prometheus [${PROM_PORT}]: " in_port
    in_port="${in_port:-$PROM_PORT}"
    if valid_port "$in_port"; then PROM_PORT="$in_port"; break; fi
    red "Invalid port (1-65535)."
  done

  while true; do
    read -rp "Version (e.g. 3.5.0, or press Enter for latest) [${PROM_VERSION:-latest}]: " in_ver
    in_ver="${in_ver:-${PROM_VERSION:-latest}}"
    in_ver="${in_ver#v}"
    if [[ "$in_ver" == "latest" ]]; then PROM_VERSION=""; break; fi
    if valid_version "$in_ver"; then PROM_VERSION="$in_ver"; break; fi
    red "Invalid version format. Use something like 3.5.0"
  done
fi

valid_port "$PROM_PORT" || die "Invalid port: $PROM_PORT"
if [[ -n "$PROM_VERSION" ]]; then
  valid_version "$PROM_VERSION" || die "Invalid version: $PROM_VERSION (use e.g. 3.5.0)"
fi

# ---------- port conflict check ----------
# A running Prometheus (re-install) is allowed to keep its port.
if port_in_use "$PROM_PORT" && ! systemctl is-active --quiet prometheus; then
  red "Port $PROM_PORT is already in use by:"
  ss -ltnp "sport = :$PROM_PORT" || true
  [[ "$ASSUME_YES" == "yes" ]] && die "Choose another port with -p."
  while true; do
    read -rp "Enter a different port: " in_port
    if valid_port "$in_port" && ! port_in_use "$in_port"; then PROM_PORT="$in_port"; break; fi
    red "Invalid or busy port."
  done
fi

# ---------- resolve version ----------
if [[ -z "$PROM_VERSION" ]]; then
  info "Looking up latest Prometheus release"
  PROM_VERSION="$(curl -fsSL --max-time 15 https://api.github.com/repos/prometheus/prometheus/releases/latest \
                  | grep -m1 '"tag_name"' | sed -E 's/.*"v?([0-9][^"]*)".*/\1/' || true)"
  if ! valid_version "${PROM_VERSION:-}"; then
    red "Could not determine latest version; falling back to ${FALLBACK_VERSION}"
    PROM_VERSION="$FALLBACK_VERSION"
  fi
fi

case "$(uname -m)" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

PKG="prometheus-${PROM_VERSION}.linux-${ARCH}"
BASE_URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}"

# ---------- download + verify ----------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "Downloading Prometheus ${PROM_VERSION} (${ARCH})"
curl -fL --progress-bar -o "$TMP/${PKG}.tar.gz" "${BASE_URL}/${PKG}.tar.gz" \
  || die "Download failed. Check the version (${PROM_VERSION}) and network access."

info "Verifying checksum"
curl -fsSL -o "$TMP/sha256sums.txt" "${BASE_URL}/sha256sums.txt" || die "Could not fetch checksums."
( cd "$TMP" && grep " ${PKG}.tar.gz\$" sha256sums.txt | sha256sum -c - ) || die "Checksum mismatch!"

tar -xzf "$TMP/${PKG}.tar.gz" -C "$TMP"
SRC="$TMP/${PKG}"

# ---------- user & directories ----------
info "Creating user and directories"
id -u "$PROM_USER" &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin "$PROM_USER"
mkdir -p "$CONF_DIR" "$DATA_DIR"

if systemctl is-active --quiet prometheus; then systemctl stop prometheus; fi

install -m 0755 "$SRC/prometheus" "$BIN_DIR/prometheus"
install -m 0755 "$SRC/promtool"   "$BIN_DIR/promtool"

if [[ ! -f "$CONF_DIR/prometheus.yml" ]]; then
  cat > "$CONF_DIR/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["127.0.0.1:${PROM_PORT}"]
EOF
else
  info "Existing prometheus.yml kept (update its self-scrape target to port ${PROM_PORT} if it changed)"
fi

if [[ -d "$SRC/consoles" ]];          then cp -r "$SRC/consoles"          "$CONF_DIR/"; fi
if [[ -d "$SRC/console_libraries" ]]; then cp -r "$SRC/console_libraries" "$CONF_DIR/"; fi

chown -R "$PROM_USER:$PROM_USER" "$CONF_DIR" "$DATA_DIR"
promtool check config "$CONF_DIR/prometheus.yml" >/dev/null || die "Invalid prometheus.yml"

# ---------- systemd ----------
info "Creating systemd service"
cat > "$SERVICE" <<EOF
[Unit]
Description=Prometheus Monitoring
Documentation=https://prometheus.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
User=${PROM_USER}
Group=${PROM_USER}
Type=simple
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=${BIN_DIR}/prometheus \\
  --config.file=${CONF_DIR}/prometheus.yml \\
  --storage.tsdb.path=${DATA_DIR} \\
  --storage.tsdb.retention.time=${RETENTION} \\
  --web.listen-address=0.0.0.0:${PROM_PORT} \\
  --web.enable-lifecycle
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now prometheus

# ---------- firewall ----------
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  if [[ "$OPEN_FIREWALL" == "ask" && "$ASSUME_YES" != "yes" ]]; then
    read -rp "UFW is active. Open port ${PROM_PORT}/tcp? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then OPEN_FIREWALL="yes"; fi
  fi
  if [[ "$OPEN_FIREWALL" == "yes" ]]; then
    ufw allow "${PROM_PORT}/tcp" >/dev/null
    info "UFW: opened ${PROM_PORT}/tcp"
  fi
fi

# ---------- verify ----------
info "Waiting for Prometheus to become ready"
ok="no"
for _ in $(seq 1 20); do
  if curl -fsS "http://127.0.0.1:${PROM_PORT}/-/ready" >/dev/null 2>&1; then ok="yes"; break; fi
  sleep 1
done

echo
if [[ "$ok" == "yes" ]]; then
  SERVER_IP="$(ip -4 -o addr show scope global | awk 'NR==1{print $4}' | cut -d/ -f1)"
  green "Prometheus ${PROM_VERSION} is running."
  echo "  URL:      http://${SERVER_IP:-<server-ip>}:${PROM_PORT}"
  echo "  Config:   ${CONF_DIR}/prometheus.yml"
  echo "  Reload:   curl -X POST http://127.0.0.1:${PROM_PORT}/-/reload"
  echo "  Data:     ${DATA_DIR}  (retention ${RETENTION})"
  echo "  Service:  systemctl status prometheus | journalctl -u prometheus -f"
  echo
  echo "To change the port later: edit --web.listen-address in ${SERVICE},"
  echo "then: systemctl daemon-reload && systemctl restart prometheus"
else
  red "Prometheus did not become ready. Recent logs:"
  journalctl -u prometheus -n 30 --no-pager || true
  exit 1
fi
