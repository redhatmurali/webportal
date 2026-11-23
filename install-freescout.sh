#!/usr/bin/env bash
#===============================================================================
# FreeScout (help desk) installer - Ubuntu 24.04, NO Docker / containers.
# Stack: Nginx + PHP-FPM + MariaDB, FreeScout from git (github.com/freescout-help-desk/freescout)
#
# Usage:
#   sudo bash install-freescout.sh --version 1.8.150 --port 3010
#   sudo bash install-freescout.sh -v latest -p 3010
#   sudo FS_INSTALL_VERSION=1.8.150 FS_INSTALL_PORT=3010 bash install-freescout.sh
#
#   version = FreeScout release tag, e.g. 1.8.150 ("latest" = newest release tag)
#   port    = port Nginx listens on (default 8080)
#
# CREDENTIALS NEVER CHANGE:
#   DB password, admin email and admin password are created ONCE in
#   /etc/freescout/credentials.env and reused on every later run
#   (upgrade, port change, re-run). The app key in .env is also kept.
#   To choose your own admin login, export FS_ADMIN_EMAIL / FS_ADMIN_PASSWORD
#   before the FIRST install only.
#===============================================================================
set -euo pipefail

FS_VERSION="${FS_INSTALL_VERSION:-latest}"
PORT="${FS_INSTALL_PORT:-8080}"

usage() {
  echo "Usage: sudo bash $0 [--version TAG|latest] [--port N]"
  echo "  -v, --version   FreeScout release tag (default: latest)"
  echo "  -p, --port      HTTP port (default: 8080)"
  exit "${1:-0}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) FS_VERSION="${2:-}"; shift 2 ;;
    -p|--port)    PORT="${2:-}"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

APP_DIR=/var/www/freescout
CONF_DIR=/etc/freescout
CRED_FILE="${CONF_DIR}/credentials.env"
NGINX_CONF=/etc/nginx/sites-available/freescout
REPO=https://github.com/freescout-help-desk/freescout.git
DB_NAME=freescout
DB_USER=freescout

log() { echo -e "\e[1;32m[FreeScout]\e[0m $*"; }
err() { echo -e "\e[1;31m[ERR ]\e[0m $*" >&2; }

[[ $EUID -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
  || { err "Invalid port: $PORT"; exit 1; }
[[ -n "$FS_VERSION" ]] || { err "Version cannot be empty."; exit 1; }
FS_VERSION="${FS_VERSION#v}"

if [[ -r /etc/os-release ]]; then
  OS_ID="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
  [[ "$OS_ID" == "ubuntu" ]] || echo "Warning: targets Ubuntu 24.04 (found ID=${OS_ID:-unknown})." >&2
fi

# Port check (skip if Nginx already serves FreeScout on this very port)
OLD_PORT=""
[[ -f "$NGINX_CONF" ]] && OLD_PORT="$(sed -n 's/^\s*listen \([0-9]*\);.*/\1/p' "$NGINX_CONF" | head -n1)"
if [[ "$PORT" != "$OLD_PORT" ]] && ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
  err "Port ${PORT} is already in use by another process."; exit 1
fi

export DEBIAN_FRONTEND=noninteractive

#--- 1. Packages ----------------------------------------------------------------
log "Installing Nginx, PHP, MariaDB and tools..."
apt-get update -qq
apt-get install -y -qq nginx mariadb-server git curl unzip openssl ca-certificates cron \
  php-fpm php-cli php-mysql php-mbstring php-xml php-curl php-gd php-zip php-intl \
  php-bcmath php-imap php-opcache >/dev/null

PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"
PHP_FPM_SVC="php${PHP_VER}-fpm"
log "PHP ${PHP_VER}"

cat > "/etc/php/${PHP_VER}/fpm/conf.d/99-freescout.ini" <<EOF
upload_max_filesize = 50M
post_max_size = 50M
max_execution_time = 120
memory_limit = 256M
EOF

systemctl enable --now mariadb "$PHP_FPM_SVC" nginx cron >/dev/null 2>&1

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
ADMIN_EMAIL=${FS_ADMIN_EMAIL:-admin@freescout.local}
ADMIN_PASS=${FS_ADMIN_PASSWORD:-$(openssl rand -hex 12)}
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
if [[ "$FS_VERSION" == "latest" ]]; then
  FS_VERSION="$(git ls-remote --tags --refs "$REPO" \
    | sed 's#.*refs/tags/##' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)"
  [[ -n "$FS_VERSION" ]] || { err "Could not resolve latest version."; exit 1; }
fi
log "Installing FreeScout ${FS_VERSION} on port ${PORT}"

as_www() { sudo -u www-data -H bash -c "cd '$APP_DIR' && $*"; }

mkdir -p "$APP_DIR"; chown www-data:www-data "$APP_DIR"
if [[ -d "$APP_DIR/.git" ]]; then
  as_www "git fetch --tags --force --quiet && git checkout -f --quiet '${FS_VERSION}'" \
    || { err "Tag '${FS_VERSION}' not found. List: git ls-remote --tags $REPO"; exit 1; }
else
  sudo -u www-data -H git clone --quiet "$REPO" "$APP_DIR" \
    || { err "Clone failed."; exit 1; }
  as_www "git checkout -f --quiet '${FS_VERSION}'" \
    || { err "Tag '${FS_VERSION}' not found. List: git ls-remote --tags $REPO"; exit 1; }
fi

#--- 5. .env (APP_KEY kept; URL/port refreshed every run) -----------------------
SERVER_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
ENV_FILE="$APP_DIR/.env"
if [[ ! -s "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<EOF
APP_URL=http://${SERVER_IP}:${PORT}
APP_FORCE_HTTPS=false
APP_KEY=
APP_DEBUG=false
APP_ENV=production
APP_TIMEZONE=Asia/Kolkata
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}
EOF
  chown www-data:www-data "$ENV_FILE"; chmod 640 "$ENV_FILE"
else
  # keep everything (incl. APP_KEY and a custom APP_URL/domain); only repair DB creds
  sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" "$ENV_FILE"
  # APP_URL: refresh only if it still points at a bare IP:port we generated
  if grep -qE '^APP_URL=http://[0-9.]+:[0-9]+$' "$ENV_FILE"; then
    sed -i "s|^APP_URL=.*|APP_URL=http://${SERVER_IP}:${PORT}|" "$ENV_FILE"
  fi
fi
grep -qE '^APP_KEY=.+' "$ENV_FILE" || as_www "php artisan key:generate --force >/dev/null"

#--- 6. Permissions, migrate, admin user ---------------------------------------
chown -R www-data:www-data "$APP_DIR"
find "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" -type d -exec chmod 775 {} + 2>/dev/null || true
chmod -R ug+rwX "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null || true

log "Running migrations..."
as_www "php artisan migrate --force"
as_www "php artisan storage:link >/dev/null 2>&1 || true"
as_www "php artisan freescout:after-app-update >/dev/null 2>&1 || php artisan freescout:clear-cache >/dev/null 2>&1 || true"

if [[ -n "$NEW_INSTALL" ]]; then
  log "Creating admin user..."
  as_www "php artisan freescout:create-user --role=admin --firstName=Admin --lastName=User --email='${ADMIN_EMAIL}' --password='${ADMIN_PASS}' --no_interaction" \
    || echo "WARNING: could not create admin user (may already exist)." >&2
fi
chown -R www-data:www-data "$APP_DIR"

#--- 7. Nginx -------------------------------------------------------------------
log "Configuring Nginx on port ${PORT}..."
cat > "$NGINX_CONF" <<EOF
server {
    listen ${PORT};
    listen [::]:${PORT};
    server_name _;
    root ${APP_DIR}/public;
    index index.php index.html;
    client_max_body_size 50M;
    error_log ${APP_DIR}/storage/logs/web-server.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 120;
    }
    location ~* ^/storage/attachment/ {
        expires 1M;
        access_log off;
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~* ^/(?:css|js)/.*\.(?:css|js)\$ {
        expires 2d;
        access_log off;
        add_header Cache-Control "public, must-revalidate";
    }
    location ~* ^/(?:css|fonts|img|installer|js|modules|[^\\\\\/]+\/)?.*\.(?:css|js|eot|woff|woff2|ttf|svg|png|jpg|jpeg|gif|ico)\$ {
        expires 1M;
        access_log off;
        add_header Cache-Control "public";
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ /\. {
        deny all;
    }
}
EOF
ln -sfn "$NGINX_CONF" /etc/nginx/sites-enabled/freescout
[[ "$PORT" == "80" ]] && rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 || { nginx -t; err "Nginx config test failed."; exit 1; }
systemctl restart "$PHP_FPM_SVC"
systemctl reload nginx

#--- 8. Cron (FreeScout runs its queue worker from the scheduler) ---------------
cat > /etc/cron.d/freescout <<EOF
* * * * * www-data /usr/bin/php ${APP_DIR}/artisan schedule:run >> /dev/null 2>&1
EOF
chmod 644 /etc/cron.d/freescout

#--- 9. Health ------------------------------------------------------------------
log "Waiting for FreeScout on :${PORT}..."
OK=""
for _ in $(seq 1 30); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/login" || true)"
  if [[ "$CODE" =~ ^(200|301|302)$ ]]; then OK=1; break; fi
  sleep 2
done
[[ -n "$OK" ]] || { err "No valid response. Check: tail ${APP_DIR}/storage/logs/web-server.log"; exit 1; }

echo
echo "========== FreeScout ${FS_VERSION} RUNNING =========="
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
echo "Logs     : ${APP_DIR}/storage/logs/"
echo "Behind a domain/HTTPS: edit APP_URL in ${APP_DIR}/.env, set APP_FORCE_HTTPS=true"
echo "====================================================="
