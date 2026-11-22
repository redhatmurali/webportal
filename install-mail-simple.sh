#!/usr/bin/env bash
# Minimal test install: Postfix + Rspamd + Nginx on Ubuntu 24.04
# No domain, no hostname setup, no IP allow-list. Just run it.
#   Postfix: 25, 465, 587    Rspamd: 11332 milter, 11333 worker, 11334 controller
#   Nginx  : http://<server-ip>/  -> Rspamd web UI
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

WEB_PORT="${WEB_PORT:-8080}"   # Nginx port for the Rspamd web UI (change as you like)
PASS="$(openssl rand -base64 12 | tr -d '=+/')"
IP="$(hostname -I | awk '{print $1}')"

echo "==> Installing packages"
apt-get update -y
apt-get install -y curl gnupg lsb-release ca-certificates ssl-cert nginx redis-server
install -d /etc/apt/keyrings
curl -fsSL https://rspamd.com/apt-stable/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/rspamd.gpg
echo "deb [signed-by=/etc/apt/keyrings/rspamd.gpg] https://rspamd.com/apt-stable/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/rspamd.list
apt-get update -y
echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
apt-get install -y postfix rspamd

echo "==> Rspamd"
cat > /etc/rspamd/local.d/worker-proxy.inc <<'EOF'
bind_socket = "127.0.0.1:11332";
milter = yes;
timeout = 120s;
upstream "local" { default = yes; self_scan = yes; }
EOF
echo 'bind_socket = "127.0.0.1:11333";' > /etc/rspamd/local.d/worker-normal.inc
HASH="$(rspamadm pw --quiet --password "$PASS")"
cat > /etc/rspamd/local.d/worker-controller.inc <<EOF
bind_socket = "127.0.0.1:11334";
password = "$HASH";
enable_password = "$HASH";
EOF
echo 'servers = "127.0.0.1";' > /etc/rspamd/local.d/redis.conf
systemctl enable --now redis-server
systemctl enable rspamd && systemctl restart rspamd

echo "==> Postfix"
postconf -e 'smtpd_tls_cert_file = /etc/ssl/certs/ssl-cert-snakeoil.pem'
postconf -e 'smtpd_tls_key_file = /etc/ssl/private/ssl-cert-snakeoil.key'
postconf -e 'smtpd_tls_security_level = may'
postconf -e 'milter_protocol = 6'
postconf -e 'milter_default_action = accept'
postconf -e 'smtpd_milters = inet:127.0.0.1:11332'
postconf -e 'non_smtpd_milters = $smtpd_milters'
postconf -e 'milter_mail_macros = i {mail_addr} {client_addr} {client_name} {auth_authen}'

# enable 587 (submission) and 465 (smtps) listeners
sed -i '/^# --- test-ports ---/,/^# --- end ---/d' /etc/postfix/master.cf
cat >> /etc/postfix/master.cf <<'EOF'
# --- test-ports ---
submission inet n - y - - smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
smtps inet n - y - - smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
# --- end ---
EOF
systemctl enable postfix && systemctl restart postfix

echo "==> Nginx"
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/conf.d/rspamd.conf <<EOF
server {
    listen ${WEB_PORT};
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:11334/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF
nginx -t && systemctl enable --now nginx && systemctl reload nginx

if command -v ufw >/dev/null; then
  for p in 25 465 587 "$WEB_PORT"; do ufw allow $p/tcp >/dev/null; done
fi

echo
echo "==> Listening ports"
ss -ltnp | grep -E ":(25|$WEB_PORT|465|587|11332|11333|11334)\b" || true
echo
echo "Rspamd UI : http://$IP:$WEB_PORT/"
echo "Password  : $PASS"
echo "Test mail : echo test | mail -s hi root   (then: tail /var/log/mail.log)"
