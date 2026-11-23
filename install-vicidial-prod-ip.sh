#!/usr/bin/env bash
#===============================================================================
# Production VICIdial + WebRTC Bare-Metal Installer (Ubuntu 24.04 x86_64)
# IP-Address Mode (No Domain/Email Required) - 100% Open Source, Zero Docker
#
# Usage:
#   sudo bash install-vicidial-prod-ip.sh --timezone Asia/Kolkata --lan
#   sudo bash install-vicidial-prod-ip.sh --timezone Asia/Kolkata
#
# Options:
#   --lan               Bind WebRTC WSS & WebPhone URLs to local LAN IP instead of Public IP
#   --rev N|latest      VICIdial SVN revision (default: latest)
#   --timezone ZONE     Set server & PHP timezone (e.g., Asia/Kolkata)
#   --allow-shared      Bypass fresh-server check (not recommended)
#===============================================================================
set -euo pipefail

REV="${VICI_INSTALL_REV:-latest}"
TZ_ZONE=""
USE_LAN=""
ALLOW_SHARED=""

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lan)          USE_LAN=1; shift ;;
    --rev)          REV="${2:-}"; shift 2 ;;
    --timezone)     TZ_ZONE="${2:-}"; shift 2 ;;
    --allow-shared) ALLOW_SHARED=1; shift ;;
    -h|--help)      usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

log()  { echo -e "\e[1;32m[VICIdial-PROD]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*" >&2; }
err()  { echo -e "\e[1;31m[ERR ]\e[0m $*" >&2; }

[[ $EUID -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }
[[ "$REV" == "latest" || "$REV" =~ ^[0-9]+$ ]] || { err "--rev must be a number or 'latest'"; exit 1; }

OS_ID="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
OS_VER="$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
[[ "$OS_ID" == "ubuntu" && "$OS_VER" == "24.04" ]] || { err "Requires Ubuntu 24.04 (found ${OS_ID} ${OS_VER})."; exit 1; }
[[ "$(uname -m)" == "x86_64" ]] || { err "x86_64 architecture required."; exit 1; }

MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
(( MEM_MB >= 1800 )) || { err "Minimum 2 GB RAM required (found ${MEM_MB} MB)."; exit 1; }
(( MEM_MB >= 7500 )) || warn "Only ${MEM_MB} MB RAM detected. Recommended 8 GB+ for live calling floors."

AST_TARBALL="asterisk-18.21.0-vici"
VICI_BASE="https://download.vicidial.com/required-apps"
SVN_URL="svn://svn.eflo.net/agc_2-X/trunk"
SRC="/usr/src"
TRUNK="${SRC}/astguiclient/trunk"
STATE="/var/lib/vicidial-install"
STAGES="${STATE}/stages"
CONF_DIR="/etc/vicidial-install"
CRED="${CONF_DIR}/credentials.env"
SSL_DIR="/etc/asterisk/keys"
AST_VER_TAG="18.X"

mkdir -p "$STAGES" "$CONF_DIR" "$SSL_DIR" "$SRC"
chmod 700 "$CONF_DIR"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
APT_OPTS=(-o DPkg::Lock::Timeout=120 -y -qq)

fetch() {
  local url="$1" out="$2"
  rm -f "$out"
  curl -fSL --retry 5 --retry-delay 3 --connect-timeout 20 "$url" -o "$out"
}

# Fresh-server check
if [[ ! -f "$STATE/started" ]]; then
  CLASH=()
  systemctl is-active --quiet nginx   2>/dev/null && CLASH+=("Nginx running")
  systemctl is-active --quiet apache2 2>/dev/null && CLASH+=("Apache running")
  { systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysql 2>/dev/null; } && CLASH+=("MariaDB/MySQL running")
  command -v fwconsole >/dev/null 2>&1 && CLASH+=("FreePBX installed")
  { pgrep -x asterisk >/dev/null 2>&1 || command -v asterisk >/dev/null 2>&1; } && CLASH+=("Asterisk present")
  if (( ${#CLASH[@]} > 0 )) && [[ -z "$ALLOW_SHARED" ]]; then
    err "Existing services detected on this host:"
    for c in "${CLASH[@]}"; do echo "   - $c" >&2; done
    err "Use a clean Ubuntu 24.04 server or pass --allow-shared."
    exit 1
  fi
  touch "$STATE/started"
fi

stage() {
  local n="$1" f="$2" rc
  if [[ -f "$STAGES/$n" ]]; then
    log "Stage '$n' already completed - skipping"
    return 0
  fi
  log "Running stage: $n"
  set +e
  ( set -e; "$f" )
  rc=$?
  set -e
  if (( rc != 0 )); then
    err "Stage '$n' failed (exit $rc). Fix the issue and re-run the exact same command."
    exit 1
  fi
  touch "$STAGES/$n"
}

#--- Timezone & Network Detection -----------------------------------------------
if [[ -n "$TZ_ZONE" ]]; then
  timedatectl set-timezone "$TZ_ZONE"
fi
SYS_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"

SERVER_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
[[ -n "$SERVER_IP" ]] || SERVER_IP="$(hostname -I | awk '{print $1}')"
[[ -n "$SERVER_IP" ]] || { err "Unable to detect primary local IP."; exit 1; }
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "$SERVER_IP")"

if [[ -n "$USE_LAN" ]]; then
  WEB_IP="$SERVER_IP"
else
  WEB_IP="$PUBLIC_IP"
fi

#--- Persistent Credentials -----------------------------------------------------
NEW_CREDS=""
if [[ ! -f "$CRED" ]]; then
  NEW_CREDS=1
  umask 077
  cat > "$CRED" <<CREDS
CRON_DB_PASS=$(openssl rand -hex 12)
CUSTOM_DB_PASS=$(openssl rand -hex 12)
ADMIN_PASS=$(openssl rand -hex 10)
TURN_PASS=$(openssl rand -hex 16)
CREDS
  chmod 600 "$CRED"
  umask 022
fi
cred() { sed -n "s/^$1=//p" "$CRED" | head -n1; }
CRON_DB_PASS="$(cred CRON_DB_PASS)"
CUSTOM_DB_PASS="$(cred CUSTOM_DB_PASS)"
ADMIN_PASS="$(cred ADMIN_PASS)"
TURN_PASS="$(cred TURN_PASS)"

#=============================== STAGES =========================================

st_packages() {
  apt-get -o DPkg::Lock::Timeout=120 update -qq
  apt-get install "${APT_OPTS[@]}" \
    build-essential pkg-config autoconf automake libtool shtool autogen \
    subversion git wget curl unzip screen sox lame mpg123 chrony openssl ca-certificates \
    linux-headers-"$(uname -r)" libelf-dev \
    apache2 libapache2-mod-php php php-cli php-mysql php-mbstring php-gd php-curl php-xml php-zip php-ldap php-bcmath \
    mariadb-server mariadb-client libmariadb-dev \
    libncurses-dev libnewt-dev libssl-dev libxml2-dev libsqlite3-dev sqlite3 uuid-dev libjansson-dev \
    libedit-dev libcurl4-openssl-dev libogg-dev libspeex-dev libgsm1-dev libsrtp2-dev libopus-dev \
    xmlstarlet bison flex coturn ufw fail2ban \
    cpanminus perl libasterisk-agi-perl sipsak \
    libdbi-perl libdbd-mysql-perl libnet-telnet-perl libnet-server-perl libmail-sendmail-perl \
    libjcode-pm-perl libspreadsheet-writeexcel-perl libole-storage-lite-perl libproc-processtable-perl \
    libio-stringy-perl libspreadsheet-parseexcel-perl libcurses-perl libterm-readkey-perl \
    libspreadsheet-xlsx-perl libspreadsheet-read-perl libwww-perl libhtml-strip-perl libhtml-format-perl \
    libhtml-tree-perl libmime-tools-perl libmail-pop3client-perl libmail-imapclient-perl \
    libio-socket-ssl-perl libcrypt-eksblowfish-perl libtext-csv-perl libswitch-perl libyaml-perl \
    libtime-hires-perl >/dev/null

  for m in Digest::MD5 Digest::SHA1 DBI DBD::mysql Net::Telnet Time::HiRes Net::Server Mail::Sendmail \
           Unicode::Map Jcode Switch Spreadsheet::WriteExcel OLE::Storage_Lite Proc::ProcessTable IO::Scalar \
           Spreadsheet::ParseExcel Curses Getopt::Long Net::Domain Term::ReadKey Term::ANSIColor \
           Spreadsheet::XLSX Spreadsheet::Read LWP::UserAgent HTML::Entities HTML::Strip HTML::FormatText \
           HTML::TreeBuilder Time::Local MIME::Decoder Mail::POP3Client Mail::IMAPClient Mail::Message \
           IO::Socket::SSL MIME::Base64 MIME::QuotedPrint Crypt::Eksblowfish::Bcrypt Text::CSV; do
    perl -M"$m" -e1 2>/dev/null || cpanm -n "$m" >/dev/null 2>&1 || warn "Optional CPAN module $m failed"
  done

  if ! perl -MAsterisk -e1 2>/dev/null; then
    cd "$SRC"
    fetch "${VICI_BASE}/asterisk-perl-0.08.tar.gz" "${SRC}/asterisk-perl-0.08.tar.gz"
    tar xzf "${SRC}/asterisk-perl-0.08.tar.gz" -C "$SRC"
    cd "${SRC}/asterisk-perl-0.08"
    perl Makefile.PL >/dev/null
    make >/dev/null
    make install >/dev/null
  fi
}

st_mariadb() {
  cat > /etc/mysql/mariadb.conf.d/99-vicidial.cnf <<'SQLCONF'
[mysqld]
sql_mode = NO_ENGINE_SUBSTITUTION
explicit_defaults_for_timestamp = Off
max_connections = 1000
max_allowed_packet = 64M
open_files_limit = 32768
innodb_buffer_pool_size = 1G
innodb_flush_log_at_trx_commit = 2
skip-name-resolve
SQLCONF
  systemctl enable --now mariadb >/dev/null 2>&1
  systemctl restart mariadb
}

st_dahdi() {
  cd "$SRC"
  rm -rf "${SRC}"/dahdi-linux-complete-*
  curl -fSL --retry 5 --retry-delay 3 --connect-timeout 20 \
    "https://downloads.asterisk.org/pub/telephony/dahdi-linux-complete/dahdi-linux-complete-current.tar.gz" \
    | tar xzf - -C "$SRC"
  cd "${SRC}"/dahdi-linux-complete-*
  make
  make install
  make install-config
  [[ -f /etc/dahdi/system.conf ]] || { mkdir -p /etc/dahdi; touch /etc/dahdi/system.conf; }
  depmod -a
  modprobe dahdi || { err "modprobe dahdi failed. If on Ubuntu 24.04 HWE 6.11+ kernel, boot into 6.8 GA kernel."; return 1; }
  echo "dahdi" > /etc/modules-load.d/dahdi.conf
}

st_asterisk() {
  log "Downloading and extracting ${AST_TARBALL}..."
  rm -rf "${SRC}"/asterisk-18.*
  curl -fSL --retry 5 --retry-delay 3 --connect-timeout 20 \
    "${VICI_BASE}/${AST_TARBALL}.tar.gz" | tar xzf - -C "$SRC"
  cd "${SRC}"/asterisk-18.*
  rm -f menuselect.makeopts
  ./configure --libdir=/usr/lib \
    --with-gsm=internal \
    --with-pjproject-bundled \
    --with-jansson-bundled \
    --with-opus \
    --with-srtp \
    --with-ssl
  make menuselect.makeopts
  menuselect/menuselect \
    --disable BUILD_NATIVE \
    --enable app_meetme \
    --enable chan_sip \
    --enable codec_opus \
    --enable res_srtp \
    --enable res_http_websocket \
    menuselect.makeopts || true
  make -j"$(nproc)"
  make install
  make samples

  if [[ -x /usr/local/sbin/asterisk && ! -e /usr/sbin/asterisk ]]; then
    ln -sf /usr/local/sbin/asterisk /usr/sbin/asterisk
  fi
  if [[ -x /usr/local/sbin/astcanary && ! -e /usr/sbin/astcanary ]]; then
    ln -sf /usr/local/sbin/astcanary /usr/sbin/astcanary
  fi
  command -v asterisk >/dev/null 2>&1 || { err "Asterisk compilation failed: binary missing."; return 1; }
  ldconfig
  asterisk -V
  mkdir -p /var/lib/asterisk/sounds /var/lib/asterisk/moh /var/spool/asterisk/monitor /var/spool/asterisk/monitorDONE "$SSL_DIR"
}

st_sounds() {
  cd /var/lib/asterisk/sounds
  for f in asterisk-core-sounds-en-gsm-current asterisk-core-sounds-en-ulaw-current \
           asterisk-core-sounds-en-wav-current asterisk-extra-sounds-en-ulaw-current \
           asterisk-extra-sounds-en-wav-current; do
    if fetch "${VICI_BASE}/${f}.tar.gz" "/tmp/${f}.tar.gz"; then
      tar xzf "/tmp/${f}.tar.gz" -C /var/lib/asterisk/sounds || warn "Extract ${f} failed"
    else
      warn "Download ${f} skipped"
    fi
    rm -f "/tmp/${f}.tar.gz"
  done
  cd /var/lib/asterisk/moh
  for f in asterisk-moh-freeplay-gsm asterisk-moh-freeplay-ulaw asterisk-moh-freeplay-wav; do
    if fetch "${VICI_BASE}/${f}.tar.gz" "/tmp/${f}.tar.gz"; then
      tar xzf "/tmp/${f}.tar.gz" -C /var/lib/asterisk/moh || warn "Extract ${f} failed"
    else
      warn "Download ${f} skipped"
    fi
    rm -f "/tmp/${f}.tar.gz"
  done
}

st_svn() {
  mkdir -p "${SRC}/astguiclient"
  cd "${SRC}/astguiclient"
  rm -rf trunk
  if [[ "$REV" == "latest" ]]; then
    svn checkout --non-interactive "$SVN_URL" trunk
  else
    svn checkout --non-interactive -r "$REV" "$SVN_URL" trunk
  fi
  [[ -f "$TRUNK/install.pl" ]] || { err "SVN checkout failed: install.pl not found."; return 1; }
}

st_database() {
  mysql <<SQLDB
SET GLOBAL connect_timeout=60;
CREATE DATABASE IF NOT EXISTS \`asterisk\` DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
CREATE USER IF NOT EXISTS 'cron'@'localhost' IDENTIFIED BY '${CRON_DB_PASS}';
ALTER USER 'cron'@'localhost' IDENTIFIED BY '${CRON_DB_PASS}';
CREATE USER IF NOT EXISTS 'custom'@'localhost' IDENTIFIED BY '${CUSTOM_DB_PASS}';
ALTER USER 'custom'@'localhost' IDENTIFIED BY '${CUSTOM_DB_PASS}';
GRANT SELECT,INSERT,UPDATE,DELETE,LOCK TABLES ON asterisk.* TO 'cron'@'localhost';
GRANT SELECT,INSERT,UPDATE,DELETE,LOCK TABLES ON asterisk.* TO 'custom'@'localhost';
GRANT RELOAD ON *.* TO 'cron'@'localhost';
GRANT RELOAD ON *.* TO 'custom'@'localhost';
FLUSH PRIVILEGES;
SQLDB
  local have
  have="$(mysql -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='asterisk' AND table_name='vicidial_users'")"
  if [[ "$have" == "0" ]]; then
    mysql asterisk < "$TRUNK/extras/MySQL_AST_CREATE_tables.sql"
    mysql asterisk < "$TRUNK/extras/first_server_install.sql"
    mysql asterisk -e "ALTER TABLE phones ALTER template_id SET DEFAULT '';" || true
  fi
}

st_vicidial() {
  cat > /etc/astguiclient.conf <<ASTCONF
PATHhome => /usr/share/astguiclient
PATHlogs => /var/log/astguiclient
PATHagi => /var/lib/asterisk/agi-bin
PATHweb => /var/www/html
PATHsounds => /var/lib/asterisk/sounds
PATHmonitor => /var/spool/asterisk/monitor
PATHDONEmonitor => /var/spool/asterisk/monitorDONE

VARserver_ip => ${SERVER_IP}

VARDB_server => localhost
VARDB_database => asterisk
VARDB_user => cron
VARDB_pass => ${CRON_DB_PASS}
VARDB_custom_user => custom
VARDB_custom_pass => ${CUSTOM_DB_PASS}
VARDB_port => 3306

VARactive_keepalives => 1234569

VARfastagi_log_min_servers => 3
VARfastagi_log_max_servers => 16
VARfastagi_log_min_spare_servers => 2
VARfastagi_log_max_spare_servers => 8
VARfastagi_log_max_requests => 1000
VARfastagi_log_checkfordead => 30
VARfastagi_log_checkforwait => 60

VARasterisk_version => ${AST_VER_TAG}

VARFTP_host => 127.0.0.1
VARFTP_user => cron
VARFTP_pass => test
VARFTP_port => 21
VARFTP_dir => RECORDINGS
VARHTTP_path => https://${WEB_IP}

VARREPORT_host => 127.0.0.1
VARREPORT_user => cron
VARREPORT_pass => test
VARREPORT_port => 21
VARREPORT_dir => REPORTS
ASTCONF
  chmod 644 /etc/astguiclient.conf
  mkdir -p /var/www/html /var/log/astguiclient
  cd "$TRUNK"
  perl install.pl --no-prompt --web=/var/www/html --asterisk_version="${AST_VER_TAG}" --copy_sample_conf_files
  sed -i -E "s|^VARserver_ip *=>.*|VARserver_ip => ${SERVER_IP}|" /etc/astguiclient.conf
  sed -i -E "s|^VARasterisk_version *=>.*|VARasterisk_version => ${AST_VER_TAG}|" /etc/astguiclient.conf

  yes '' | perl /usr/share/astguiclient/ADMIN_area_code_populate.pl >/dev/null 2>&1 || true
  perl /usr/share/astguiclient/ADMIN_update_server_ip.pl --old-server_ip=10.10.10.15 --new-server_ip="${SERVER_IP}" --auto

  mysql asterisk <<SQLVICI
UPDATE servers SET
  server_ip='${SERVER_IP}',
  asterisk_version='18.21.0',
  rebuild_conf_files='Y',
  generate_vicidial_conf='Y',
  active_asterisk_server='Y',
  web_socket_url='wss://${WEB_IP}:8089/ws',
  external_web_socket_url='wss://${WEB_IP}:8089/ws';
UPDATE vicidial_users SET pass='${ADMIN_PASS}' WHERE user='6666';
SQLVICI

  mysql -N -B -e "SELECT DISTINCT table_name FROM information_schema.columns WHERE table_schema='asterisk' AND column_name='server_ip'" \
    | while read -r t; do mysql asterisk -e "UPDATE \`${t}\` SET server_ip='${SERVER_IP}' WHERE server_ip='';" || true; done

  local srv_ok
  srv_ok="$(mysql -N -B asterisk -e "SELECT COUNT(*) FROM servers WHERE server_ip='${SERVER_IP}'")"
  [[ "$srv_ok" -ge 1 ]] || { err "Failed to set server_ip=${SERVER_IP} in servers table."; return 1; }

  if [[ -f /etc/asterisk/manager.conf ]]; then
    sed -i -E 's/^bindaddr *=.*/bindaddr = 127.0.0.1/' /etc/asterisk/manager.conf
  fi
}

st_ssl_apache() {
  local PHPV
  PHPV="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  for sapi in apache2 cli; do
    [[ -d "/etc/php/${PHPV}/${sapi}/conf.d" ]] && cat > "/etc/php/${PHPV}/${sapi}/conf.d/99-vicidial.ini" <<PHPINI
short_open_tag = On
memory_limit = 512M
max_execution_time = 330
max_input_vars = 10000
upload_max_filesize = 64M
post_max_size = 64M
display_errors = Off
error_reporting = E_ALL & ~E_NOTICE & ~E_WARNING & ~E_DEPRECATED & ~E_STRICT
date.timezone = ${SYS_TZ}
PHPINI
  done

  cat > "${SSL_DIR}/openssl-ip.cnf" <<SSLCNF
[req]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[dn]
CN = ${WEB_IP}

[req_ext]
subjectAltName = @alt_names

[alt_names]
IP.1 = ${PUBLIC_IP}
IP.2 = ${SERVER_IP}
SSLCNF

  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "${SSL_DIR}/vicidial.key" \
    -out "${SSL_DIR}/vicidial.crt" \
    -config "${SSL_DIR}/openssl-ip.cnf" \
    -extensions req_ext >/dev/null 2>&1
  chmod 644 "${SSL_DIR}/vicidial.crt" "${SSL_DIR}/vicidial.key"

  a2enmod ssl rewrite headers >/dev/null 2>&1

  cat > /etc/apache2/sites-available/vicidial.conf <<APACHECONF
<VirtualHost *:80>
    ServerName ${WEB_IP}
    RewriteEngine On
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName ${WEB_IP}
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile ${SSL_DIR}/vicidial.crt
    SSLCertificateKeyFile ${SSL_DIR}/vicidial.key

    Alias /RECORDINGS/ "/var/spool/asterisk/monitorDONE/"
    <Directory "/var/spool/asterisk/monitorDONE/">
        Options Indexes MultiViews
        AllowOverride None
        Require all granted
    </Directory>

    <Directory "/var/www/html">
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
APACHECONF
  echo "ServerName ${WEB_IP}" > /etc/apache2/conf-available/servername.conf
  a2enconf servername >/dev/null 2>&1 || true
  a2dissite 000-default default-ssl >/dev/null 2>&1 || true
  a2ensite vicidial >/dev/null 2>&1
  systemctl enable --now apache2 >/dev/null 2>&1
  systemctl restart apache2
}

st_webrtc_turn() {
  cd /var/www/html
  rm -rf ViciPhone
  git clone --depth 1 https://github.com/vicimikec/ViciPhone.git ViciPhone
  chown -R www-data:www-data /var/www/html/ViciPhone
  chmod -R 755 /var/www/html/ViciPhone

  VP_ENTRY="viciphone.html"
  if [[ ! -f "/var/www/html/ViciPhone/${VP_ENTRY}" ]]; then
    VP_ENTRY="$(find /var/www/html/ViciPhone -maxdepth 1 -name '*.html' -printf '%f\n' | head -n1)"
    [[ -n "$VP_ENTRY" ]] || VP_ENTRY="viciphone.html"
  fi

  cat > /etc/asterisk/http.conf <<HTTPCONF
[general]
enabled=yes
enablestatic=yes
bindaddr=0.0.0.0
bindport=8088
tlsenable=yes
tlsbindaddr=0.0.0.0:8089
tlscertfile=${SSL_DIR}/vicidial.crt
tlsprivatekey=${SSL_DIR}/vicidial.key
HTTPCONF

  cat > /etc/turnserver.conf <<TURNCONF
listening-port=3478
tls-listening-port=5349
listening-ip=${SERVER_IP}
external-ip=${PUBLIC_IP}/${SERVER_IP}
realm=${WEB_IP}
server-name=${WEB_IP}
lt-cred-mech
user=vicidial:${TURN_PASS}
cert=${SSL_DIR}/vicidial.crt
pkey=${SSL_DIR}/vicidial.key
no-stdout-log
log-file=/var/log/turnserver.log
fingerprint
no-multicast-peers
no-cli
TURNCONF
  sed -i 's/^#*TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null || echo 'TURNSERVER_ENABLED=1' > /etc/default/coturn
  systemctl enable --now coturn >/dev/null 2>&1
  systemctl restart coturn

  cat > /etc/asterisk/rtp.conf <<RTPCONF
[general]
rtpstart=10000
rtpend=20000
icesupport=yes
stunaddr=stun.l.google.com:19302
turnaddr=${WEB_IP}:3478
turnusername=vicidial
turnpassword=${TURN_PASS}
RTPCONF

  if [[ -f /etc/asterisk/sip.conf ]]; then
    grep -q '^transport=' /etc/asterisk/sip.conf || sed -i '/^\[general\]/a transport=udp,ws,wss' /etc/asterisk/sip.conf
    if [[ "$PUBLIC_IP" != "$SERVER_IP" ]]; then
      grep -q '^externip=' /etc/asterisk/sip.conf || sed -i "/^\[general\]/a externip=${PUBLIC_IP}\nlocalnet=10.0.0.0/8\nlocalnet=172.16.0.0/12\nlocalnet=192.168.0.0/16" /etc/asterisk/sip.conf
    fi
  fi

  mysql asterisk <<SQLWEBRTC
REPLACE INTO vicidial_conf_templates (template_id, template_name, template_contents) VALUES (
  'WEBRTC',
  'Production WebRTC ViciPhone v3',
  'type=friend\nhost=dynamic\ncontext=default\ntrustrpid=yes\nsendrpid=no\nqualify=yes\nqualifyfreq=30\nnat=force_rport,comedia\ntransport=wss,ws,udp\nencryption=yes\navpf=yes\nicesupport=yes\nrtcp_mux=yes\ndirectmedia=no\ndtlsenabl=yes\ndtlsenable=yes\ndtlsverify=fingerprint\ndtlscertfile=${SSL_DIR}/vicidial.crt\ndtlsprivatekey=${SSL_DIR}/vicidial.key\ndtlssetup=actpass\ndisallow=all\nallow=opus\nallow=ulaw\nallow=alaw'
);

UPDATE system_settings SET
  webphone_url='https://${WEB_IP}/ViciPhone/${VP_ENTRY}',
  default_webphone='1';
SQLWEBRTC
}

st_cron() {
  cat > /etc/cron.d/vicidial <<'CRONVICI'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * root /usr/share/astguiclient/AST_CRON_audio_1_move_mix.pl
0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * root /usr/share/astguiclient/AST_CRON_audio_1_move_mix.pl --MIX
0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * root /usr/share/astguiclient/AST_CRON_audio_1_move_VDonly.pl
1,4,7,10,13,16,19,22,25,28,31,34,37,40,43,46,49,52,55,58 * * * * root /usr/share/astguiclient/AST_CRON_audio_2_compress.pl --GSM

* * * * * root /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --cu3way
* * * * * root /usr/share/astguiclient/AST_manager_kill_hung_congested.pl

* * * * * root /usr/share/astguiclient/AST_vm_update.pl
* * * * * root /usr/share/astguiclient/AST_conf_update.pl
11 * * * * root /usr/share/astguiclient/AST_flush_DBqueue.pl -q
33 * * * * root /usr/share/astguiclient/AST_cleanup_agent_log.pl
50 0 * * * root /usr/share/astguiclient/AST_cleanup_agent_log.pl --last-24hours
* * * * * root /usr/share/astguiclient/AST_VDhopper.pl -q

1 1,7 * * * root /usr/share/astguiclient/ADMIN_adjust_GMTnow_on_leads.pl --debug
45 0 * * * root /usr/share/astguiclient/ADMIN_adjust_GMTnow_on_leads.pl --list-settings
2 1 * * * root /usr/share/astguiclient/AST_reset_mysql_vars.pl
3 1 * * * root /usr/share/astguiclient/AST_DB_optimize.pl
2 0 * * 0 root /usr/share/astguiclient/AST_agent_week.pl
22 0 * * * root /usr/share/astguiclient/AST_agent_day.pl
25 0 * * * root /usr/share/astguiclient/AST_DB_dead_cb_purge.pl --purge-non-cb -q
1 7 * * * root /usr/share/astguiclient/AST_dialer_inventory_snapshot.pl -q --override-24hours
* * * * * root /usr/share/astguiclient/AST_inbound_email_parser.pl
30 1 1 * * root /usr/share/astguiclient/ADMIN_archive_log_tables.pl

28 0 * * * root /usr/bin/find /var/log/astguiclient -maxdepth 1 -type f -mtime +2 -delete
29 0 * * * root /usr/bin/find /var/log/asterisk -maxdepth 3 -type f -mtime +2 -delete
CRONVICI
  chmod 644 /etc/cron.d/vicidial
}

st_security_service() {
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow 8089/tcp >/dev/null
  ufw allow 5060/udp >/dev/null
  ufw allow 5060/tcp >/dev/null
  ufw allow 10000:20000/udp >/dev/null
  ufw allow 3478/udp >/dev/null
  ufw allow 3478/tcp >/dev/null
  ufw --force enable >/dev/null

  cat > /etc/fail2ban/jail.d/vicidial.conf <<'F2BCONF'
[sshd]
enabled = true
maxretry = 5
bantime = 3600

[asterisk]
enabled = true
port = 5060,5061,8089
protocol = all
logpath = /var/log/asterisk/messages
maxretry = 5
findtime = 600
bantime = 86400
F2BCONF
  systemctl enable --now fail2ban >/dev/null 2>&1
  systemctl restart fail2ban

  cat > /etc/systemd/system/vicidial.service <<'SVCUNIT'
[Unit]
Description=VICIdial Telephony Engine (DAHDI + Asterisk + astguiclient)
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe dahdi
ExecStartPre=-/usr/sbin/dahdi_cfg -vvvv
ExecStartPre=/usr/share/astguiclient/AST_reset_mysql_vars.pl
ExecStartPre=/usr/share/astguiclient/ADMIN_restart_roll_logs.pl
ExecStart=/usr/share/astguiclient/start_asterisk_boot.pl
ExecStartPost=/bin/sleep 5
ExecStartPost=/usr/share/astguiclient/ADMIN_keepalive_ALL.pl --cu3way

[Install]
WantedBy=multi-user.target
SVCUNIT
  systemctl daemon-reload
  systemctl enable vicidial >/dev/null 2>&1
}

#=============================== EXECUTION ======================================
log "Starting Production VICIdial + WebRTC install (Web IP: ${WEB_IP}, LAN: ${SERVER_IP}, Public: ${PUBLIC_IP})"
stage packages         st_packages
stage mariadb          st_mariadb
stage dahdi            st_dahdi
stage asterisk         st_asterisk
stage sounds           st_sounds
stage svn              st_svn
stage database         st_database
stage vicidial         st_vicidial
stage ssl_apache       st_ssl_apache
stage webrtc_turn      st_webrtc_turn
stage cron             st_cron
stage security_service st_security_service

# Re-assert VARserver_ip & DB server_ip before starting services
sed -i -E "s|^VARserver_ip *=>.*|VARserver_ip => ${SERVER_IP}|" /etc/astguiclient.conf
mysql asterisk -e "UPDATE servers SET server_ip='${SERVER_IP}', rebuild_conf_files='Y', generate_vicidial_conf='Y', active_asterisk_server='Y';"

systemctl start vicidial || warn "Check journalctl -u vicidial -e"

# Wait up to 30s for Asterisk AMI (port 5038) to come online before generating configs
for _ in $(seq 1 15); do
  if ss -ltn | grep -q ':5038 '; then break; fi
  sleep 2
done

/usr/share/astguiclient/AST_conf_update.pl
/usr/sbin/asterisk -rx "module reload http" >/dev/null 2>&1 || true

SCREENS="$(screen -ls 2>/dev/null | grep -c 'Detached' || true)"
VP_URL="$(mysql -N -B asterisk -e "SELECT webphone_url FROM system_settings LIMIT 1;" 2>/dev/null || echo "https://${WEB_IP}/ViciPhone/viciphone.html")"

echo
echo "================ PRODUCTION VICIdial + WebRTC READY ================"
echo "Admin URL      : https://${WEB_IP}/vicidial/admin.php"
echo "Admin User     : 6666"
echo "Admin Password : ${ADMIN_PASS}"
echo "Agent URL      : https://${WEB_IP}/agc/vicidial.php"
echo "WebSocket WSS  : wss://${WEB_IP}:8089/ws"
echo "WebPhone URL   : ${VP_URL}"
echo "TURN Server    : turn:${WEB_IP}:3478  (user: vicidial / pass: ${TURN_PASS})"
echo "Credentials    : Saved in ${CRED}"
echo "Screen Daemons : ${SCREENS} running (9 expected)"
echo "Verify CLI     : asterisk -rx 'http show status' ; asterisk -rx 'manager show connected' ; screen -ls"
echo "===================================================================="
