#!/usr/bin/env bash
#===============================================================================
# FreePBX manual installer for Ubuntu 24.04 - Nginx + PHP-FPM + MariaDB +
# Asterisk (Ubuntu package). NO Docker/containers, NO Apache.
#
# Sangoma's official installer only supports Debian 12, so this follows the
# manual FreePBX source install and serves it with Nginx (UNOFFICIAL setup).
#
# Usage:
#   sudo bash install-freepbx.sh --port 3060
#   sudo bash install-freepbx.sh --port 3060 --version 17.0
#   sudo PBX_INSTALL_PORT=3060 bash install-freepbx.sh
#
#   port    = Nginx port for the FreePBX web interface (default 8084)
#   version = FreePBX series to download (default 17.0)
#
# CREDENTIALS NEVER CHANGE: the database password FreePBX uses is created once
# in /etc/freepbx-install/credentials.env and reused on every re-run.
# The FreePBX admin user is created in the browser on your first visit.
# Re-running: if FreePBX is already installed, only the Nginx port changes.
#
# Caveats: FreePBX 17 targets PHP 8.2; Ubuntu 24.04 ships PHP 8.3. Asterisk
# comes from Ubuntu's repository (20.x). Review any errors in the output.
#===============================================================================
set -euo pipefail

PORT="${PBX_INSTALL_PORT:-8084}"
FPBX_SERIES="${PBX_INSTALL_VERSION:-17.0}"

usage() {
  echo "Usage: sudo bash $0 [--port N] [--version SERIES]"
  echo "  -p, --port      Web interface port (default: 8084)"
  echo "  -v, --version   FreePBX series, e.g. 17.0 (default: 17.0)"
  exit "${1:-0}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)    PORT="${2:-}"; shift 2 ;;
    -v|--version) FPBX_SERIES="${2:-}"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

WEBROOT=/var/www/freepbx
SRC_DIR=/usr/src/freepbx
STATE_DIR=/etc/freepbx-install
CRED_FILE="${STATE_DIR}/credentials.env"
NGINX_CONF=/etc/nginx/sites-available/freepbx
FPM_SOCK=/run/php/freepbx-fpm.sock
DB_USER=freepbxuser

log() { echo -e "\e[1;32m[FreePBX]\e[0m $*"; }
err() { echo -e "\e[1;31m[ERR ]\e[0m $*" >&2; }

[[ $EUID -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
  || { err "Invalid port: $PORT"; exit 1; }
[[ "$FPBX_SERIES" =~ ^[0-9]+\.[0-9]+$ ]] || { err "Version must look like 17.0"; exit 1; }

if [[ -r /etc/os-release ]]; then
  OS_ID="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
  OS_VER="$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
  [[ "$OS_ID" == "ubuntu" && "$OS_VER" == "24.04" ]] \
    || echo "Warning: written for Ubuntu 24.04 (found ${OS_ID} ${OS_VER})." >&2
fi

# Port check (skip if Nginx already serves FreePBX on this very port)
OLD_PORT=""
[[ -f "$NGINX_CONF" ]] && OLD_PORT="$(sed -n 's/^\s*listen \([0-9]*\);.*/\1/p' "$NGINX_CONF" | head -n1)"
if [[ "$PORT" != "$OLD_PORT" ]] && ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
  err "Port ${PORT} is already in use by another process."; exit 1
fi

export DEBIAN_FRONTEND=noninteractive

#--- 1. Packages ----------------------------------------------------------------
# Note: no "php" metapackage (it pulls in Apache); php-fpm/php-cli are used.
log "Installing dependencies (this takes a while)..."
apt-get update -qq
apt-get install -y -qq build-essential wget curl ca-certificates sudo cron \
  libncurses-dev libssl-dev libsqlite3-dev pkg-config \
  mariadb-server nginx \
  php-fpm php-cli php-common php-pear php-cgi php-curl php-mbstring php-gd php-mysql \
  php-xml php-bcmath php-zip php-intl php-soap php-ldap php-sqlite3 \
  unixodbc odbc-mariadb incron sox mpg123 lame net-tools \
  asterisk >/dev/null
# Node: reuse the one already on the server (e.g. NodeSource); only add Ubuntu's if missing
command -v node >/dev/null 2>&1 || apt-get install -y -qq nodejs npm >/dev/null

PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_FPM_SVC="php${PHP_VER}-fpm"
log "PHP ${PHP_VER}, Node $(node -v 2>/dev/null || echo none)"

systemctl enable --now mariadb nginx "$PHP_FPM_SVC" >/dev/null 2>&1

#--- 2. Skip straight to the port step if FreePBX is already installed ---------
INSTALLED=""
command -v fwconsole >/dev/null 2>&1 && INSTALLED=1

if [[ -z "$INSTALLED" ]]; then
  #--- 3. Database --------------------------------------------------------------
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  if [[ ! -f "$CRED_FILE" ]]; then
    umask 077
    echo "DB_PASS=$(openssl rand -hex 16)" > "$CRED_FILE"
    chmod 600 "$CRED_FILE"; umask 022
  fi
  DB_PASS="$(sed -n 's/^DB_PASS=//p' "$CRED_FILE" | head -n1)"
  [[ -n "$DB_PASS" ]] || { err "Empty DB password in ${CRED_FILE}."; exit 1; }

  # FreePBX needs a non-strict SQL mode (shared MariaDB: this relaxes strictness for all apps)
  cat > /etc/mysql/mariadb.conf.d/99-freepbx.cnf <<EOF
[mysqld]
sql_mode = NO_ENGINE_SUBSTITUTION
EOF
  systemctl restart mariadb

  log "Preparing databases..."
  mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`asterisk\` CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS \`asteriskcdrdb\` CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`asterisk\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`asteriskcdrdb\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

  #--- 4. PHP-FPM pool running as the asterisk user -----------------------------
  log "Creating PHP-FPM pool for FreePBX..."
  cat > "/etc/php/${PHP_VER}/fpm/pool.d/freepbx.conf" <<EOF
[freepbx]
user = asterisk
group = asterisk
listen = ${FPM_SOCK}
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 20
pm.start_servers = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 6
php_admin_value[memory_limit] = 256M
php_admin_value[upload_max_filesize] = 120M
php_admin_value[post_max_size] = 120M
php_admin_value[max_execution_time] = 300
EOF
  systemctl restart "$PHP_FPM_SVC"

  #--- 5. Asterisk must be running before FreePBX installs ---------------------
  systemctl enable --now asterisk >/dev/null 2>&1 || true
  sleep 3
  pgrep -x asterisk >/dev/null || { err "Asterisk is not running. Check: journalctl -u asterisk -e"; exit 1; }

  #--- 6. Download FreePBX ------------------------------------------------------
  log "Downloading FreePBX ${FPBX_SERIES}..."
  rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  BASE_URL="https://mirror.freepbx.org/modules/packages/freepbx"
  wget -q -O "$TMP/f.tgz" "${BASE_URL}/freepbx-${FPBX_SERIES}-latest.tgz" \
    || wget -q -O "$TMP/f.tgz" "${BASE_URL}/freepbx-${FPBX_SERIES}-latest-EDGE.tgz" \
    || { err "Download failed for FreePBX ${FPBX_SERIES} from ${BASE_URL}/"; exit 1; }
  tar -xzf "$TMP/f.tgz" -C "$SRC_DIR" --strip-components=1
  rm -rf "$TMP"; trap - EXIT

  #--- 7. Install ---------------------------------------------------------------
  mkdir -p "$WEBROOT"; chown asterisk:asterisk "$WEBROOT"
  log "Running the FreePBX installer..."
  ( cd "$SRC_DIR" && ./install -n \
      --dbuser="${DB_USER}" --dbpass="${DB_PASS}" \
      --webroot="${WEBROOT}" --user=asterisk --group=asterisk ) || INSTALL_RC=$?
  # The installer can exit non-zero on minor warnings even when it succeeded:
  # trust the result, not the exit code.
  if [[ -x /usr/sbin/fwconsole || -x /var/lib/asterisk/bin/fwconsole ]]; then
    [[ "${INSTALL_RC:-0}" -ne 0 ]] && echo "NOTE: installer exited with code ${INSTALL_RC} but FreePBX is installed - continuing." >&2
  else
    err "FreePBX install failed. Review the output above."; exit 1
  fi

  log "Installing modules and reloading..."
  fwconsole ma installall >/dev/null 2>&1 || echo "WARNING: module install reported errors (run: fwconsole ma installall)" >&2
  fwconsole chown >/dev/null 2>&1 || true
  fwconsole reload >/dev/null 2>&1 || true
else
  log "FreePBX already installed - only applying the web port."
fi

#--- 8. Nginx -------------------------------------------------------------------
log "Configuring Nginx on port ${PORT}..."
cat > "$NGINX_CONF" <<EOF
server {
    listen ${PORT};
    listen [::]:${PORT};
    server_name _;
    root ${WEBROOT};
    index index.php;
    client_max_body_size 120M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${FPM_SOCK};
        fastcgi_read_timeout 300;
    }
    # Apache's .htaccess protections do not apply under Nginx - deny sensitive files
    location ~* \.(inc|module|sql|ini|log|bak|sh|conf|yml|yaml|lock)\$ {
        deny all;
    }
    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
ln -sfn "$NGINX_CONF" /etc/nginx/sites-enabled/freepbx
[[ "$PORT" == "80" ]] && rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 || { nginx -t; err "Nginx config test failed."; exit 1; }
systemctl reload nginx

#--- 9. Health ------------------------------------------------------------------
OK=""
for _ in $(seq 1 20); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/admin/" || true)"
  if [[ "$CODE" =~ ^(200|301|302|401)$ ]]; then OK=1; break; fi
  sleep 2
done
[[ -n "$OK" ]] || { err "No response on port ${PORT}. Check: tail /var/log/nginx/error.log"; exit 1; }

SERVER_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
echo
echo "========== FreePBX READY =========="
echo "Web UI   : http://${SERVER_IP}:${PORT}/admin"
echo "Login    : none yet - the first visit asks you to create the admin user"
echo "Database : asterisk / asteriskcdrdb (user ${DB_USER}, password in ${CRED_FILE})"
echo "Ports to open for phones/trunks: SIP UDP/TCP 5060 (5061 TLS), RTP UDP 10000-20000"
echo "Manage   : fwconsole reload | fwconsole restart | fwconsole ma list"
echo "Logs     : /var/log/asterisk/   /var/log/nginx/error.log"
echo "Security : restrict the web port and SIP ports (UFW/Fail2ban/CrowdSec) before going live."
echo "==================================="
