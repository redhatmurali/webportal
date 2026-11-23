#!/usr/bin/env bash
#===============================================================================
# Redmine installer for Ubuntu 24.04 - NO Docker/containers.
# Stack: Ruby 3.2 (Ubuntu) + Puma + MariaDB, Redmine from the official tarball.
#
# Usage:
#   sudo bash install-redmine.sh --version 6.0.5 --port 3030
#   sudo bash install-redmine.sh -v latest -p 3030
#   sudo RM_INSTALL_VERSION=6.0.5 RM_INSTALL_PORT=3030 bash install-redmine.sh
#
#   version = Redmine release (e.g. 6.0.5, 5.1.8); "latest" = newest release
#   port    = port Puma listens on (default 3000)
#
# CREDENTIALS NEVER CHANGE:
#   DB password, admin password and the secret key are created ONCE in
#   /etc/redmine/credentials.env and reused on every later run (upgrade, port
#   change, re-run). The admin login name is "admin".
#   To choose your own admin password / email, export RM_ADMIN_PASSWORD /
#   RM_ADMIN_EMAIL before the FIRST install only.
#
# Layout:  /opt/redmine/releases/redmine-<ver>   (one per version)
#          /opt/redmine/current                  (symlink to active release)
#          /var/lib/redmine/{files,log,config}   (shared data, kept on upgrade)
#===============================================================================
set -euo pipefail

RM_VERSION="${RM_INSTALL_VERSION:-latest}"
PORT="${RM_INSTALL_PORT:-3000}"

usage() {
  echo "Usage: sudo bash $0 [--version X.Y.Z|latest] [--port N]"
  echo "  -v, --version   Redmine version (default: latest)"
  echo "  -p, --port      HTTP port (default: 3000)"
  exit "${1:-0}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) RM_VERSION="${2:-}"; shift 2 ;;
    -p|--port)    PORT="${2:-}"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

BASE_DIR=/opt/redmine
REL_DIR="${BASE_DIR}/releases"
CURRENT="${BASE_DIR}/current"
SHARED=/var/lib/redmine
CONF_DIR=/etc/redmine
CRED_FILE="${CONF_DIR}/credentials.env"
SERVICE=/etc/systemd/system/redmine.service
DB_NAME=redmine
DB_USER=redmine

log() { echo -e "\e[1;32m[Redmine]\e[0m $*"; }
err() { echo -e "\e[1;31m[ERR ]\e[0m $*" >&2; }

[[ $EUID -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
  || { err "Invalid port: $PORT"; exit 1; }
[[ -n "$RM_VERSION" ]] || { err "Version cannot be empty."; exit 1; }
RM_VERSION="${RM_VERSION#v}"

if [[ -r /etc/os-release ]]; then
  OS_ID="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
  [[ "$OS_ID" == "ubuntu" ]] || echo "Warning: targets Ubuntu 24.04 (found ID=${OS_ID:-unknown})." >&2
fi

if ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
  systemctl is-active --quiet redmine || { err "Port ${PORT} is already in use by another process."; exit 1; }
fi

export DEBIAN_FRONTEND=noninteractive

#--- 1. Packages ----------------------------------------------------------------
log "Installing Ruby, build tools and MariaDB..."
apt-get update -qq
apt-get install -y -qq ruby ruby-dev bundler build-essential pkg-config git curl openssl \
  ca-certificates mariadb-server libmariadb-dev libxml2-dev libxslt1-dev libyaml-dev \
  libssl-dev zlib1g-dev imagemagick ghostscript >/dev/null
systemctl enable --now mariadb >/dev/null 2>&1
log "Ruby $(ruby -e 'print RUBY_VERSION')"

#--- 2. Resolve version ---------------------------------------------------------
if [[ "$RM_VERSION" == "latest" ]]; then
  RM_VERSION="$(git ls-remote --tags --refs https://github.com/redmine/redmine.git \
    | sed 's#.*refs/tags/##' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)"
  [[ -n "$RM_VERSION" ]] || { err "Could not resolve latest version; pass --version."; exit 1; }
fi
log "Installing Redmine ${RM_VERSION} on port ${PORT}"

#--- 3. User & directories ------------------------------------------------------
id redmine &>/dev/null || useradd --system --home-dir "$BASE_DIR" --shell /bin/bash redmine
mkdir -p "$REL_DIR" "$SHARED"/{files,log,config} "$CONF_DIR"
chown -R redmine:redmine "$BASE_DIR" "$SHARED"
chmod 700 "$CONF_DIR"

#--- 4. Credentials (created once, never changed) -------------------------------
NEW_INSTALL=""
if [[ -f "$CRED_FILE" ]]; then
  log "Existing credentials found in ${CRED_FILE} - keeping them unchanged"
else
  NEW_INSTALL=1
  umask 077
  cat > "$CRED_FILE" <<EOF
DB_PASS=$(openssl rand -hex 16)
ADMIN_EMAIL=${RM_ADMIN_EMAIL:-admin@redmine.local}
ADMIN_PASS=${RM_ADMIN_PASSWORD:-$(openssl rand -hex 12)}
SECRET_KEY_BASE=$(openssl rand -hex 64)
EOF
  chmod 600 "$CRED_FILE"
  umask 022
fi
cred() { sed -n "s/^$1=//p" "$CRED_FILE" | head -n1; }
DB_PASS="$(cred DB_PASS)"; ADMIN_EMAIL="$(cred ADMIN_EMAIL)"
ADMIN_PASS="$(cred ADMIN_PASS)"; SECRET="$(cred SECRET_KEY_BASE)"
[[ -n "$DB_PASS" && -n "$ADMIN_EMAIL" && -n "$ADMIN_PASS" && -n "$SECRET" ]] \
  || { err "Empty credential in ${CRED_FILE}."; exit 1; }

#--- 5. Database ----------------------------------------------------------------
log "Preparing database..."
mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

cat > "${SHARED}/config/database.yml" <<EOF
production:
  adapter: mysql2
  database: ${DB_NAME}
  host: localhost
  username: ${DB_USER}
  password: "${DB_PASS}"
  encoding: utf8mb4
EOF
chown redmine:redmine "${SHARED}/config/database.yml"; chmod 600 "${SHARED}/config/database.yml"

#--- 6. Download & unpack release ----------------------------------------------
REL="${REL_DIR}/redmine-${RM_VERSION}"
systemctl stop redmine 2>/dev/null || true
PREV="$(readlink -f "$CURRENT" 2>/dev/null || true)"
FRESH=""
if [[ ! -d "$REL" ]]; then
  FRESH=1
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  log "Downloading Redmine ${RM_VERSION}..."
  curl -fSL --retry 3 -o "$TMP/r.tar.gz" "https://www.redmine.org/releases/redmine-${RM_VERSION}.tar.gz" \
    || curl -fSL --retry 3 -o "$TMP/r.tar.gz" "https://github.com/redmine/redmine/archive/refs/tags/${RM_VERSION}.tar.gz" \
    || { err "Download failed. Check that version ${RM_VERSION} exists."; exit 1; }
  tar -xzf "$TMP/r.tar.gz" -C "$TMP"
  SRC="$(find "$TMP" -maxdepth 1 -mindepth 1 -type d | head -n1)"
  mv "$SRC" "$REL"
  rm -rf "$TMP"; trap - EXIT

  # shared data + config links
  rm -rf "$REL/files" "$REL/log"
  ln -s "$SHARED/files" "$REL/files"
  ln -s "$SHARED/log"   "$REL/log"
  ln -sf "$SHARED/config/database.yml" "$REL/config/database.yml"

  # keep user-installed plugins/themes across upgrades
  if [[ -n "$PREV" && -d "$PREV/plugins" ]]; then
    cp -an "$PREV/plugins/." "$REL/plugins/" 2>/dev/null || true
    cp -an "$PREV/public/themes/." "$REL/public/themes/" 2>/dev/null || true
  fi

  # Puma (only if this Redmine's Gemfile does not already declare it)
  if ! grep -q "puma" "$REL/Gemfile"; then
    echo 'gem "puma"' > "$REL/Gemfile.local"
  fi
  chown -R redmine:redmine "$REL"
fi

run_rm() {
  sudo -u redmine -H env RAILS_ENV=production SECRET_KEY_BASE="$SECRET" REDMINE_LANG=en \
    bash -c "cd '$REL' && $*"
}

#--- 7. Gems, secrets, migrations ----------------------------------------------
log "Installing gems (several minutes on a fresh release)..."
run_rm "bundle config set --local without 'development test' && bundle config set --local path vendor/bundle && bundle install --quiet"
run_rm "bundle exec rake generate_secret_token >/dev/null 2>&1 || true"

log "Migrating database..."
run_rm "bundle exec rake db:migrate"
run_rm "bundle exec rake redmine:plugins:migrate >/dev/null 2>&1 || true"

if [[ -n "$NEW_INSTALL" ]] || [[ ! -f "${SHARED}/.initialized" ]]; then
  log "Loading default data..."
  run_rm "bundle exec rake redmine:load_default_data"

  log "Setting admin login..."
  cat > "${SHARED}/set_admin.rb" <<EOF
u = User.find_by_login('admin')
u.password = '${ADMIN_PASS}'
u.password_confirmation = '${ADMIN_PASS}'
u.must_change_passwd = false
u.mail = '${ADMIN_EMAIL}'
u.save!(validate: false)
EOF
  chown redmine:redmine "${SHARED}/set_admin.rb"
  run_rm "bundle exec rails runner -e production '${SHARED}/set_admin.rb'"
  rm -f "${SHARED}/set_admin.rb"
  touch "${SHARED}/.initialized"
fi

run_rm "bundle exec rake tmp:cache:clear tmp:sessions:clear >/dev/null 2>&1 || true"

#--- 8. Activate release & systemd ----------------------------------------------
ln -sfn "$REL" "$CURRENT"
chown -h redmine:redmine "$CURRENT"

cat > "$SERVICE" <<EOF
[Unit]
Description=Redmine (Puma)
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
User=redmine
Group=redmine
WorkingDirectory=${CURRENT}
Environment=RAILS_ENV=production
Environment=RAILS_SERVE_STATIC_FILES=true
Environment=SECRET_KEY_BASE=${SECRET}
Environment=HOME=${BASE_DIR}
ExecStart=$(command -v bundle) exec puma -e production -b tcp://0.0.0.0:${PORT} -t 2:8 -w 0
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
chmod 600 "$SERVICE"
systemctl daemon-reload
systemctl enable --now redmine
systemctl restart redmine

# keep the two newest releases
ls -1dt "${REL_DIR}"/redmine-* 2>/dev/null | tail -n +3 | xargs -r rm -rf

#--- 9. Health ------------------------------------------------------------------
log "Waiting for Redmine on :${PORT} (first boot can take ~30s)..."
OK=""
for _ in $(seq 1 60); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/login" || true)"
  if [[ "$CODE" == "200" ]]; then OK=1; break; fi
  sleep 2
done
[[ -n "$OK" ]] || { err "No response. Check: journalctl -u redmine -e   and   ${SHARED}/log/production.log"; exit 1; }

SERVER_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
echo
echo "========== Redmine ${RM_VERSION} RUNNING =========="
echo "URL      : http://${SERVER_IP}:${PORT}"
echo "Login    : admin"
echo "Password : ${ADMIN_PASS}"
echo "Email    : ${ADMIN_EMAIL}"
if [[ -n "$NEW_INSTALL" ]]; then
  echo "(generated now and saved in ${CRED_FILE}; they will never change)"
else
  echo "(unchanged, from ${CRED_FILE})"
fi
echo "Database : ${DB_NAME} (MariaDB, user ${DB_USER})"
echo "Files    : ${SHARED}/files      Logs: ${SHARED}/log/   journalctl -u redmine -f"
echo "Behind a domain: proxy to 127.0.0.1:${PORT}; set Administration > Settings > Host name."
echo "====================================================="
