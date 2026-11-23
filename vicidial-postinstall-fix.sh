#!/usr/bin/env bash
# VICIdial post-install repair for the observed Ubuntu 24.04 / Asterisk 18 setup.
# Run as root after VICIdial, its database, and the server record are installed.
# Usage: bash vicidial-postinstall-fix.sh [SERVER_IP]
set -Eeuo pipefail

CONF=/etc/astguiclient.conf
CRON=/etc/cron.d/vicidial
ASTDIR=/etc/asterisk
GENERATOR=/usr/share/astguiclient/ADMIN_keepalive_ALL.pl
SERVICE=vicidial.service
STAMP=$(date +%Y%m%d-%H%M%S)
LOG=/root/vicidial-postinstall-${STAMP}.log
MYSQL_CNF=''

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
cleanup() { [[ -n "$MYSQL_CNF" && -f "$MYSQL_CNF" ]] && rm -f "$MYSQL_CNF"; }
trap cleanup EXIT

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  die "Run this script as root."
fi

exec > >(tee -a "$LOG") 2>&1

log "VICIdial post-install repair starting"
echo "Log file: $LOG"

[[ -f "$CONF" ]] || die "$CONF not found. Install VICIdial first."
[[ -x "$GENERATOR" ]] || die "$GENERATOR not found. Install VICIdial first."
[[ -f "$ASTDIR/modules.conf" ]] || die "$ASTDIR/modules.conf not found."
[[ -f "$ASTDIR/sip.conf" ]] || die "$ASTDIR/sip.conf not found."
[[ -f /usr/lib/asterisk/modules/chan_sip.so ]] || die "chan_sip.so is not installed. This script cannot enable a missing module."
command -v mysql >/dev/null || die "mysql client is not installed."
command -v screen >/dev/null || die "screen is not installed."

get_conf() {
  local key="$1"
  awk -F'=>' -v k="$key" '
    $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
      v=$2
      sub(/^[[:space:]]*/, "", v)
      sub(/[[:space:]]*#.*/, "", v)
      sub(/[[:space:]]*;.*/, "", v)
      sub(/[[:space:]]*$/, "", v)
      print v
      exit
    }
  ' "$CONF"
}

DBUSER=$(get_conf VARDB_user)
DBPASS=$(get_conf VARDB_pass)
DBHOST=$(get_conf VARDB_server)
DBNAME=$(get_conf VARDB_database)
DBPORT=$(get_conf VARDB_port)
[[ -n "$DBUSER" && -n "$DBPASS" && -n "$DBNAME" ]] || die "Could not read VARDB_user, VARDB_pass, or VARDB_database from $CONF."
DBHOST=${DBHOST:-localhost}
DBPORT=${DBPORT:-3306}

# Prefer explicit IP, then configured IP, then the source address of the default route.
SERVER_IP=${1:-$(get_conf VARserver_ip)}
if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
fi
[[ -n "$SERVER_IP" ]] || die "Could not determine this server's IPv4 address. Run: $0 <SERVER_IP>"
if [[ ! "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  die "SERVER_IP must be an IPv4 address. Received: $SERVER_IP"
fi

log "Selected VICIdial server IP: $SERVER_IP"
echo "Database host: $DBHOST:$DBPORT"
echo "Database: $DBNAME; user: $DBUSER (password hidden)"

# Back up configuration files before making changes.
cp -a "$CONF" "${CONF}.backup.${STAMP}"
cp -a "$ASTDIR/modules.conf" "$ASTDIR/modules.conf.backup.${STAMP}"
[[ ! -f "$CRON" ]] || cp -a "$CRON" "${CRON}.backup.${STAMP}"
log "Configuration backups created with suffix .backup.${STAMP}"

# Create a private MySQL option file so the DB password is not exposed in process arguments.
MYSQL_CNF=$(mktemp /root/vicidial-mysql.XXXXXX.cnf)
chmod 600 "$MYSQL_CNF"
DBPASS_ESC=${DBPASS//\\/\\\\}
DBPASS_ESC=${DBPASS_ESC//\"/\\\"}
printf '[client]\nuser=%s\npassword="%s"\nhost=%s\nport=%s\n' \
  "$DBUSER" "$DBPASS_ESC" "$DBHOST" "$DBPORT" > "$MYSQL_CNF"
unset DBPASS DBPASS_ESC

MYSQL=(mysql --defaults-extra-file="$MYSQL_CNF" --batch --skip-column-names "$DBNAME")

log "Checking database server record"
SERVER_ROW=$("${MYSQL[@]}" -e \
  "SELECT CONCAT_WS('|',active_asterisk_server,generate_vicidial_conf,rebuild_conf_files) FROM servers WHERE server_ip='${SERVER_IP}' LIMIT 1;") || die "Could not query the VICIdial servers table. Check database credentials and schema."
[[ -n "$SERVER_ROW" ]] || die "No servers.server_ip record matches $SERVER_IP. Supply the exact IP stored in the VICIdial servers table."
IFS='|' read -r ACTIVE_FLAG GENERATE_FLAG REBUILD_FLAG <<< "$SERVER_ROW"
echo "Server flags before repair: active=$ACTIVE_FLAG generate=$GENERATE_FLAG rebuild=$REBUILD_FLAG"
[[ "$ACTIVE_FLAG" == "Y" ]] || die "Server $SERVER_IP is not marked active_asterisk_server=Y. Review the VICIdial server role before continuing."

log "Ensuring configuration generation is enabled for this server"
"${MYSQL[@]}" -e \
  "UPDATE servers SET generate_vicidial_conf='Y', rebuild_conf_files='Y' WHERE server_ip='${SERVER_IP}';" \
  || die "Could not set the VICIdial configuration-generation flags."

log "Setting VARserver_ip in astguiclient.conf"
if grep -qE '^[[:space:]]*VARserver_ip[[:space:]]*=>' "$CONF"; then
  sed -i -E "s|^[[:space:]]*VARserver_ip[[:space:]]*=>.*|VARserver_ip => ${SERVER_IP}|" "$CONF"
else
  printf '\nVARserver_ip => %s\n' "$SERVER_IP" >> "$CONF"
fi
grep -n '^VARserver_ip' "$CONF"

log "Enabling chan_sip in modules.conf"
sed -i -E \
  '/^[[:space:]]*noload[[:space:]]*=[[:space:]]*chan_sip\.so/s/^([[:space:]]*)noload/\1; noload/' \
  "$ASTDIR/modules.conf"
if ! grep -Eq '^[[:space:]]*load[[:space:]]*=[[:space:]]*chan_sip\.so' "$ASTDIR/modules.conf"; then
  printf '\nload = chan_sip.so\n' >> "$ASTDIR/modules.conf"
fi
grep -nE 'chan_sip|chan_pjsip' "$ASTDIR/modules.conf"

log "Correcting keepalive cron entry: keep normal keepalive, remove --cu3way"
if [[ -f "$CRON" ]]; then
  TMP_CRON=$(mktemp)
  awk '
    /ADMIN_keepalive_ALL\.pl/ {
      sub(/^# TEMPORARILY DISABLED:[[:space:]]*/, "")
      if ($0 !~ /^[[:space:]]*#/) {
        sub(/[[:space:]]+--cu3way([[:space:]]|$)/, " ")
        sub(/[[:space:]]+$/, "")
      }
    }
    { print }
  ' "$CRON" > "$TMP_CRON"
  cat "$TMP_CRON" > "$CRON"
  rm -f "$TMP_CRON"
  grep -n 'ADMIN_keepalive_ALL' "$CRON" || true
else
  echo "WARNING: $CRON not found; leaving cron scheduling unchanged."
fi

log "Checking VICIdial-managed Asterisk process"
if ! asterisk -rx 'core show version' >/dev/null 2>&1; then
  systemctl start "$SERVICE" || die "Asterisk is not running and systemctl could not start $SERVICE."
  for _ in $(seq 1 20); do
    if asterisk -rx 'core show version' >/dev/null 2>&1; then break; fi
    sleep 1
  done
fi
asterisk -rx 'core show version' >/dev/null 2>&1 || die "Asterisk did not become available. Check: systemctl status $SERVICE"

log "Loading chan_sip into the running Asterisk process"
asterisk -rx 'module load chan_sip.so' || true
sleep 2
CHAN_STATUS=$(asterisk -rx 'module show like chan_sip')
echo "$CHAN_STATUS"
echo "$CHAN_STATUS" | grep -q 'chan_sip.so' || die "chan_sip did not load. Inspect Asterisk logs before proceeding."
echo "$CHAN_STATUS" | grep -q 'Running' || die "chan_sip is present but not Running. Inspect Asterisk logs."

log "Running VICIdial configuration generator"
GENLOG="/root/vicidial-generator-${STAMP}.log"
set +e
"$GENERATOR" --debug 2>&1 | tee "$GENLOG"
GEN_STATUS=${PIPESTATUS[0]}
set -e
echo "Generator exit status: $GEN_STATUS"
[[ $GEN_STATUS -eq 0 ]] || die "VICIdial configuration generator failed. See $GENLOG"

log "Confirming generated files"
for f in extensions-vicidial.conf iax-vicidial.conf sip-vicidial.conf \
         pjsip-vicidial.conf pjsip_wizard-vicidial.conf meetme-vicidial.conf \
         confbridge-vicidial.conf voicemail.conf; do
  if [[ -f "$ASTDIR/$f" ]]; then
    printf '%-36s %8s bytes\n' "$f" "$(stat -c %s "$ASTDIR/$f")"
  else
    echo "MISSING: $ASTDIR/$f"
  fi
done

log "Checking database generation flags after the generator"
"${MYSQL[@]}" -e \
  "SELECT server_ip,active_asterisk_server,generate_vicidial_conf,rebuild_conf_files,conf_engine FROM servers WHERE server_ip='${SERVER_IP}';"

# The systemd unit starts one cu3way updater at boot. The cron entry above must not
# start another one every minute. Clean old duplicates and create one fresh session.
log "Cleaning duplicate ASTconf3way Screen sessions and starting one updater"
CHANNELS=$(asterisk -rx 'core show channels' 2>&1 || true)
echo "$CHANNELS"
if echo "$CHANNELS" | grep -Eq '[1-9][0-9]* active channels'; then
  echo "WARNING: Active calls detected; leaving ASTconf3way sessions untouched."
else
  while read -r session; do
    [[ -n "$session" ]] && screen -S "$session" -X quit || true
  done < <(screen -ls 2>/dev/null | awk '/ASTconf3way/ {print $1}')
  "$GENERATOR" --cu3way >/root/vicidial-cu3way-${STAMP}.log 2>&1 || \
    echo "WARNING: keepalive --cu3way returned an error; see /root/vicidial-cu3way-${STAMP}.log"
  sleep 2
  screen -ls | grep ASTconf3way || echo "No ASTconf3way Screen session currently visible."
fi

log "Final SIP and service checks"
asterisk -rx 'module show like chan_sip'
asterisk -rx 'sip show peers'
echo
echo "VICIdial service: $(systemctl is-active "$SERVICE" 2>/dev/null || true)"
echo "Asterisk version: $(asterisk -rx 'core show version' | head -1)"
echo
echo "SIP bind settings (review; not modified by this script):"
grep -nE '^[[:space:]]*(bindaddr|bindport|externip|localnet|transport)[[:space:]]*=' "$ASTDIR/sip.conf" || true

if grep -qE '^secret[[:space:]]*=[[:space:]]*test([[:space:]]|$)' "$ASTDIR/sip-vicidial.conf" 2>/dev/null; then
  echo
  echo "SECURITY WARNING: A generated SIP extension still uses secret=test. Change it in VICIdial before exposing SIP to untrusted networks."
fi

echo
echo "============================================================"
echo "VICIdial post-install repair completed."
echo "Main log: $LOG"
echo "Generator log: $GENLOG"
echo "Backups: ${CONF}.backup.${STAMP}, ${ASTDIR}/modules.conf.backup.${STAMP}"
echo "No Asterisk restart was performed by this script."
echo "============================================================"
