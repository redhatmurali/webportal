#!/usr/bin/env bash
#===============================================================================
# BookStack installer for Ubuntu 24.04 - NO Docker/containers.
# Stack: Nginx + PHP-FPM + MariaDB, BookStack from git (github.com/BookStackApp/BookStack)
#
# Usage:
#   sudo bash install-bookstack.sh --version v25.02.1 --port 3020
#   sudo bash install-bookstack.sh -v latest -p 3020
#   sudo BS_INSTALL_VERSION=v25.02.1 BS_INSTALL_PORT=3020 bash install-bookstack.sh
#
#   version = BookStack release tag (with or without leading "v"); "latest" = newest tag
#   port    = port Nginx listens on (default 8081)
#
# CREDENTIALS NEVER CHANGE:
#   DB password, admin email and admin password are created ONCE in
#   /etc/bookstack/credentials.env and reused on every later run (upgrade,
#   port change, re-run). The APP_KEY in .env is also kept.
#   To choose your own admin login, export BS_ADMIN_EMAIL / BS_ADMIN_PASSWORD
#   before the FIRST install only.
#===============================================================================
set -euo pipefail

BS_VERSION="${BS_INSTALL_VERSION:-latest}"
PORT="${BS_INSTALL_PORT:-8081}"

usage() {
  echo "Usage: sudo bash $0 [--version TAG|latest] [--port N]"
  echo "  -v, --version   BookStack release tag, e.g. v25.02.1 (default: latest)"
  echo "  -p, --port      HTTP port (default: 8081)"
  exit "${1:-0}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) BS_VERSION="${2:-}"; shift 2 ;;
    -p|--port)    PORT="${2:-}"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

APP_DIR=/var/www/bookstack
CONF_DIR=/etc/bookstack
CRED_FILE="${CONF_DIR}/credentials.env"
NGINX_CONF=/etc/nginx/sites-available/bookstack
REPO=https://github.com/BookStackApp/BookStack.git
DB_NAME=bookstack
DB_USER=bookstack

log() { echo -e "\e[1;32m[BookStack]\e[0m $*"; }
err() { echo -e "\e[1;31m[ERR ]\e[0m $*" >&2; }

[[ $EUID -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
  || { err "Invalid port: $PORT"; exit 1; }
[[ -n "$BS_VERSION" ]] || { err "Version cannot be empty."; exit 1; }

if [[ -r /etc/os-release ]]; then
  OS_ID="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
  [[ "$OS_ID" == "ubuntu" ]] || echo "Warning: targets Ubuntu 24.04 (found ID=${OS_ID:-unknown})." >&2
fi

# Port check (skip if Nginx already serves BookStack on this very port)
OLD_PORT=""
[[ -f "$NGINX_CONF" ]] && OLD_PORT="$(sed -n 's/^\s*listen \([0-9]*\);.*/\1/p' "$NGINX_CONF" | head -n1)"
if [[ "$PORT" != "$OLD_PORT" ]] && ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
  err "Port ${PORT} is already in use by another process."; exit 1
fi

export DEBIAN_FRONTEND=noninteractive

#--- 1. Packages ----------------------------------------------------------------
log "Installing Nginx, PHP, MariaDB, Composer and tools..."
apt-get update -qq
apt-get install -y -qq nginx mariadb-server git curl unzip openssl ca-certificates composer \
  php-fpm php-cli php-mysql php-mbstring php-xml php-curl php-gd php-zip php-intl \
  php-ldap php-tidy >/dev/null

PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"
PHP_FPM_SVC="php${PHP_VER}-fpm"
log "PHP ${PHP_VER}"

cat > "/etc/php/${PHP_VER}/fpm/conf.d/99-bookstack.ini" <<EOF
upload_max_filesize = 50M
post_max_size = 50M
max_execution_time = 120
memory_limit = 256M
EOF

systemctl enable --now mariadb "$PHP_FPM_SVC" nginx >/dev/null 2>&1

#--- 2. Credentials (created once, never changed) -------------------------------
mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
NEW_INSTALL=""
if [[ -f "$CRED_FILE" ]]; then
  log "Existing credentials found in ${CRED_FILE} - keeping them unchanged"
else
  NEW_INSTALL=1
  umask 077
  cat > "$CRED_FILE" <<EOF
DB_PASS=$(openssl rand -hex 16)
ADMIN_EMAIL=${BS_ADMIN_EMAIL:-admin@bookstack.local}
ADMIN_PASS=${BS_ADMIN_PASSWORD:-$(openssl rand -hex 12)}
EOF
  chmod 600 "$CRED_FILE"
  umask 022
fi
cred() { sed -n "s/^$1=//p" "$CRED_FILE" | head -n1; }
DB_PASS="$(cred DB_PASS)"; ADMIN_EMAIL="$(cred ADMIN_EMAIL)"; ADMIN_PASS="$(cred ADMIN_PASS)"
[[ -n "$DB_PASS" && -n "$ADMIN_EMAIL" && -n "$ADMIN_PASS" ]] || { err "Empty credential in ${CRED_FILE}."; exit 1; }

#--- 3. Database ----------------------------------------------------------------
log "Preparing database..."
mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

#--- 4. Source ------------------------------------------------------------------
if [[ "$BS_VERSION" == "latest" ]]; then
  BS_VERSION="$(git ls-remote --tags --refs "$REPO" \
    | sed 's#.*refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V | tail -n1)"
  [[ -n "$BS_VERSION" ]] || { err "Could not resolve latest version."; exit 1; }
fi
[[ "$BS_VERSION" == v* ]] || BS_VERSION="v${BS_VERSION}"
log "Installing BookStack ${BS_VERSION} on port ${PORT}"

as_www() { sudo -u www-data -H env COMPOSER_HOME=/tmp/composer-bookstack COMPOSER_ALLOW_SUPERUSER=0 bash -c "cd '$APP_DIR' && $*"; }

mkdir -p "$APP_DIR"; chown www-data:www-data "$APP_DIR"
if [[ -d "$APP_DIR/.git" ]]; then
  as_www "git fetch --tags --force --quiet && git checkout -f --quiet '${BS_VERSION}'" \
    || { err "Tag '${BS_VERSION}' not found. List: git ls-remote --tags $REPO"; exit 1; }
else
  sudo -u www-data -H git clone --quiet "$REPO" "$APP_DIR" || { err "Clone failed."; exit 1; }
  as_www "git checkout -f --quiet '${BS_VERSION}'" \
    || { err "Tag '${BS_VERSION}' not found. List: git ls-remote --tags $REPO"; exit 1; }
fi

log "Installing PHP dependencies with Composer (a few minutes)..."
as_www "composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader"

#--- 5. .env (APP_KEY kept; URL refreshed only if it is a bare IP:port) ---------
SERVER_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
ENV_FILE="$APP_DIR/.env"
set_env() {  # set_env KEY VALUE (overwrite or append)
  if grep -qE "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"; fi
}
if [[ ! -s "$ENV_FILE" ]]; then
  cp "$APP_DIR/.env.example" "$ENV_FILE"
  set_env APP_URL "http://${SERVER_IP}:${PORT}"
  set_env APP_KEY ""
elif grep -qE '^APP_URL=http://[0-9.]+:[0-9]+$' "$ENV_FILE"; then
  set_env APP_URL "http://${SERVER_IP}:${PORT}"
fi
set_env DB_HOST "127.0.0.1"
set_env DB_PORT "3306"
set_env DB_DATABASE "${DB_NAME}"
set_env DB_USERNAME "${DB_USER}"
set_env DB_PASSWORD "${DB_PASS}"
chown www-data:www-data "$ENV_FILE"; chmod 640 "$ENV_FILE"

# APP_KEY: generate only when missing/placeholder (never rotate an existing key)
if ! grep -qE '^APP_KEY=base64:.+' "$ENV_FILE"; then
  as_www "php artisan key:generate --force --no-interaction >/dev/null"
fi

#--- 6. Permissions, migrate, admin --------------------------------------------
chown -R www-data:www-data "$APP_DIR"
chmod -R ug+rwX "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" "$APP_DIR/public/uploads" 2>/dev/null || true

log "Running migrations..."
as_www "php artisan migrate --force --no-interaction"

# First install: turn the seeded default admin (admin@admin.com / password)
# into our fixed admin login.
DEFAULT_EXISTS="$(mysql -N -B -e "SELECT COUNT(*) FROM \`${DB_NAME}\`.users WHERE email='admin@admin.com'" 2>/dev/null || echo 0)"
if [[ "${DEFAULT_EXISTS:-0}" != "0" ]]; then
  log "Setting admin login..."
  PW_HASH="$(ADMIN_PASS="$ADMIN_PASS" php -r 'echo password_hash(getenv("ADMIN_PASS"), PASSWORD_BCRYPT);')"
  mysql <<EOF
UPDATE \`${DB_NAME}\`.users SET email='${ADMIN_EMAIL}', password='${PW_HASH}' WHERE email='admin@admin.com';
EOF
fi

as_www "php artisan cache:clear >/dev/null 2>&1; php artisan config:clear >/dev/null 2>&1; php artisan view:clear >/dev/null 2>&1 || true"
chown -R www-data:www-data "$APP_DIR"

#--- 7. Nginx -------------------------------------------------------------------
log "Configuring Nginx on port ${PORT}..."
cat > "$NGINX_CONF" <<EOF
server {
    listen ${PORT};
    listen [::]:${PORT};
    server_name _;
    root ${APP_DIR}/public;
    index index.php;
    client_max_body_size 50M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_read_timeout 120;
    }
    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
ln -sfn "$NGINX_CONF" /etc/nginx/sites-enabled/bookstack
[[ "$PORT" == "80" ]] && rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 || { nginx -t; err "Nginx config test failed."; exit 1; }
systemctl restart "$PHP_FPM_SVC"
systemctl reload nginx

#--- 8. Health ------------------------------------------------------------------
log "Waiting for BookStack on :${PORT}..."
OK=""
for _ in $(seq 1 30); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/login" || true)"
  if [[ "$CODE" =~ ^(200|301|302)$ ]]; then OK=1; break; fi
  sleep 2
done
[[ -n "$OK" ]] || { err "No valid response. Check: tail ${APP_DIR}/storage/logs/laravel.log /var/log/nginx/error.log"; exit 1; }

echo
echo "========== BookStack ${BS_VERSION} RUNNING =========="
echo "URL      : http://${SERVER_IP}:${PORT}"
echo "Admin    : ${ADMIN_EMAIL}"
echo "Password : ${ADMIN_PASS}"
if [[ -n "$NEW_INSTALL" ]]; then
  echo "(generated now and saved in ${CRED_FILE}; they will never change)"
else
  echo "(unchanged, from ${CRED_FILE})"
fi
echo "App dir  : ${APP_DIR}"
echo "Database : ${DB_NAME} (MariaDB, user ${DB_USER})"
echo "Logs     : ${APP_DIR}/storage/logs/   /var/log/nginx/error.log"
echo "Behind a domain/HTTPS: set APP_URL in ${APP_DIR}/.env (e.g. https://kb.netaport.com),"
echo "then: sudo -u www-data php ${APP_DIR}/artisan config:clear"
echo "====================================================="
