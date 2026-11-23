#!/usr/bin/env bash
#===============================================================================
# Adminer (database manager) installer for Ubuntu 24.04 - NO Docker/containers.
# Stack: Nginx + PHP-FPM, Adminer is a single PHP file.
# Works with MariaDB/MySQL, PostgreSQL and SQLite (PHP drivers are installed).
#
# Usage:
#   sudo bash install-adminer.sh --port 3050
#   sudo bash install-adminer.sh --version 5.4.1 --port 3050
#   sudo bash install-adminer.sh -v latest -p 3050
#   sudo ADM_INSTALL_PORT=3050 ADM_INSTALL_VERSION=5.4.1 bash install-adminer.sh
#
#   port    = port Nginx listens on (default 8083)
#   version = Adminer release, optional (default: latest)
#
# No credentials of its own: you log in with your database users.
# Re-running with another --port or --version just updates those.
#===============================================================================
set -euo pipefail

ADM_VERSION="${ADM_INSTALL_VERSION:-latest}"
PORT="${ADM_INSTALL_PORT:-8083}"

usage() {
  echo "Usage: sudo bash $0 [--port N] [--version X.Y.Z|latest]"
  echo "  -p, --port      HTTP port (default: 8083)"
  echo "  -v, --version   Adminer version (default: latest)"
  exit "${1:-0}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) ADM_VERSION="${2:-}"; shift 2 ;;
    -p|--port)    PORT="${2:-}"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

APP_DIR=/var/www/adminer
NGINX_CONF=/etc/nginx/sites-available/adminer

log() { echo -e "\e[1;32m[Adminer]\e[0m $*"; }
err() { echo -e "\e[1;31m[ERR ]\e[0m $*" >&2; }

[[ $EUID -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
  || { err "Invalid port: $PORT"; exit 1; }
[[ -n "$ADM_VERSION" ]] || { err "Version cannot be empty."; exit 1; }
ADM_VERSION="${ADM_VERSION#v}"

if [[ -r /etc/os-release ]]; then
  OS_ID="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
  [[ "$OS_ID" == "ubuntu" ]] || echo "Warning: targets Ubuntu 24.04 (found ID=${OS_ID:-unknown})." >&2
fi

# Port check (skip if Nginx already serves Adminer on this very port)
OLD_PORT=""
[[ -f "$NGINX_CONF" ]] && OLD_PORT="$(sed -n 's/^\s*listen \([0-9]*\);.*/\1/p' "$NGINX_CONF" | head -n1)"
if [[ "$PORT" != "$OLD_PORT" ]] && ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
  err "Port ${PORT} is already in use by another process."; exit 1
fi

export DEBIAN_FRONTEND=noninteractive

#--- 1. Packages ----------------------------------------------------------------
log "Installing Nginx and PHP-FPM with database drivers..."
apt-get update -qq
apt-get install -y -qq nginx curl ca-certificates \
  php-fpm php-cli php-mysql php-pgsql php-sqlite3 php-mbstring php-xml php-curl php-zip >/dev/null

PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"
PHP_FPM_SVC="php${PHP_VER}-fpm"

cat > "/etc/php/${PHP_VER}/fpm/conf.d/99-adminer.ini" <<EOF
upload_max_filesize = 128M
post_max_size = 128M
max_execution_time = 300
memory_limit = 512M
EOF
systemctl enable --now "$PHP_FPM_SVC" nginx >/dev/null 2>&1

#--- 2. Resolve version & download ---------------------------------------------
if [[ "$ADM_VERSION" == "latest" ]]; then
  ADM_VERSION="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    https://github.com/vrana/adminer/releases/latest | sed 's#.*/tag/v##')"
  [[ "$ADM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { err "Could not resolve latest version; pass --version."; exit 1; }
fi
log "Adminer ${ADM_VERSION} on port ${PORT}"

mkdir -p "$APP_DIR"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
curl -fSL --retry 3 -o "$TMP" \
  "https://github.com/vrana/adminer/releases/download/v${ADM_VERSION}/adminer-${ADM_VERSION}.php" \
  || { err "Download failed. Check that version v${ADM_VERSION} exists: https://github.com/vrana/adminer/releases"; exit 1; }
head -c 5 "$TMP" | grep -q '<?php' || { err "Downloaded file is not a PHP script."; exit 1; }
install -m 0644 "$TMP" "${APP_DIR}/index.php"
rm -f "$TMP"; trap - EXIT
echo "$ADM_VERSION" > "${APP_DIR}/.version"
chown -R www-data:www-data "$APP_DIR"

#--- 3. Nginx -------------------------------------------------------------------
log "Configuring Nginx on port ${PORT}..."
cat > "$NGINX_CONF" <<EOF
server {
    listen ${PORT};
    listen [::]:${PORT};
    server_name _;
    root ${APP_DIR};
    index index.php;
    client_max_body_size 128M;

    location / {
        try_files \$uri /index.php?\$query_string;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_read_timeout 300;
    }
    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
ln -sfn "$NGINX_CONF" /etc/nginx/sites-enabled/adminer
[[ "$PORT" == "80" ]] && rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 || { nginx -t; err "Nginx config test failed."; exit 1; }
systemctl restart "$PHP_FPM_SVC"
systemctl reload nginx

#--- 4. Health ------------------------------------------------------------------
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" || true)"
[[ "$CODE" == "200" ]] || { err "HTTP ${CODE}. Check: tail /var/log/nginx/error.log"; exit 1; }

SERVER_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
echo
echo "========== Adminer ${ADM_VERSION} RUNNING =========="
echo "URL      : http://${SERVER_IP}:${PORT}"
echo "Login    : your database user (no Adminer account)"
echo "  MariaDB/MySQL : System=MySQL, Server=localhost"
echo "  PostgreSQL    : System=PostgreSQL, Server=localhost"
echo "Note     : Adminer refuses logins with an empty password."
echo "Security : this page is open to anyone who can reach the port - restrict it"
echo "           (UFW allow only your IP, or put it behind your reverse proxy/auth)."
echo "===================================================="
