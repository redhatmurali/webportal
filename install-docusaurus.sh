#!/usr/bin/env bash
#===============================================================================
# Docusaurus installer for Ubuntu 24.04 - NO Docker/containers.
# Scaffolds a Docusaurus site, builds it to static files and serves it with
# Nginx on the port you choose.
#
# Usage:
#   sudo bash install-docusaurus.sh --version 3.9.2 --port 3040
#   sudo bash install-docusaurus.sh -v latest -p 3040
#   sudo DOCU_INSTALL_VERSION=3.9.2 DOCU_INSTALL_PORT=3040 bash install-docusaurus.sh
#
#   version = Docusaurus release (e.g. 3.9.2); "latest" = newest on npm
#   port    = port Nginx serves the site on (default 8082)
#
# No login/credentials: Docusaurus builds a static site.
# Your content is kept on every re-run (it is never re-scaffolded):
#   /opt/docusaurus/site/docs, blog, src, static, docusaurus.config.js
# Re-running with a different --version upgrades the @docusaurus/* packages,
# rebuilds the site and moves the port if you changed it.
#
# After editing content, rebuild with:   sudo docusaurus-rebuild
#===============================================================================
set -euo pipefail

DOC_VERSION="${DOCU_INSTALL_VERSION:-latest}"
PORT="${DOCU_INSTALL_PORT:-8082}"

usage() {
  echo "Usage: sudo bash $0 [--version X.Y.Z|latest] [--port N]"
  echo "  -v, --version   Docusaurus version (default: latest)"
  echo "  -p, --port      HTTP port (default: 8082)"
  exit "${1:-0}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) DOC_VERSION="${2:-}"; shift 2 ;;
    -p|--port)    PORT="${2:-}"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

BASE_DIR=/opt/docusaurus
SITE_DIR="${BASE_DIR}/site"
HOME_DIR=/var/lib/docusaurus
NGINX_CONF=/etc/nginx/sites-available/docusaurus

log() { echo -e "\e[1;32m[Docusaurus]\e[0m $*"; }
err() { echo -e "\e[1;31m[ERR ]\e[0m $*" >&2; }

[[ $EUID -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
  || { err "Invalid port: $PORT"; exit 1; }
[[ -n "$DOC_VERSION" ]] || { err "Version cannot be empty."; exit 1; }
DOC_VERSION="${DOC_VERSION#v}"

if [[ -r /etc/os-release ]]; then
  OS_ID="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
  [[ "$OS_ID" == "ubuntu" ]] || echo "Warning: targets Ubuntu 24.04 (found ID=${OS_ID:-unknown})." >&2
fi

# Port check (skip if Nginx already serves this site on that very port)
OLD_PORT=""
[[ -f "$NGINX_CONF" ]] && OLD_PORT="$(sed -n 's/^\s*listen \([0-9]*\);.*/\1/p' "$NGINX_CONF" | head -n1)"
if [[ "$PORT" != "$OLD_PORT" ]] && ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
  err "Port ${PORT} is already in use by another process."; exit 1
fi

export DEBIAN_FRONTEND=noninteractive

#--- 1. Packages & Node ---------------------------------------------------------
log "Installing Nginx, Git and build tools..."
apt-get update -qq
apt-get install -y -qq nginx git curl ca-certificates build-essential >/dev/null

NODE_MAJOR=0
command -v node >/dev/null 2>&1 && NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if (( NODE_MAJOR < 20 )); then
  log "Installing Node.js 22 (Docusaurus 3 needs Node 20+)..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
log "Node $(node -v)"

#--- 2. Resolve version ---------------------------------------------------------
if [[ "$DOC_VERSION" == "latest" ]]; then
  DOC_VERSION="$(npm view @docusaurus/core version 2>/dev/null || true)"
  [[ -n "$DOC_VERSION" ]] || { err "Could not resolve latest version; pass --version."; exit 1; }
fi
npm view "@docusaurus/core@${DOC_VERSION}" version >/dev/null 2>&1 \
  || { err "Docusaurus ${DOC_VERSION} not found on npm. List: npm view @docusaurus/core versions"; exit 1; }
log "Docusaurus ${DOC_VERSION} on port ${PORT}"

#--- 3. User --------------------------------------------------------------------
id docusaurus &>/dev/null || useradd --system --home-dir "$HOME_DIR" --shell /bin/bash docusaurus
mkdir -p "$BASE_DIR" "$HOME_DIR"
chown -R docusaurus:docusaurus "$BASE_DIR" "$HOME_DIR"
chmod 755 "$BASE_DIR"

as_doc() { sudo -u docusaurus -H bash -c "$*"; }

SERVER_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

# Docusaurus's progress bar (webpackbar) breaks with webpack >= 5.106 (strict
# option validation). Pin webpack below that via npm "overrides".
# Returns 10 when package.json was changed (a clean reinstall is then needed).
pin_webpack() {
  local rc=0
  as_doc "cd '$SITE_DIR' && node -e \"
    const fs=require('fs'),p=JSON.parse(fs.readFileSync('package.json'));
    const want='>=5.95.0 <5.106.0';
    p.overrides=p.overrides||{};
    if (p.overrides.webpack===want) process.exit(0);
    p.overrides.webpack=want;
    fs.writeFileSync('package.json', JSON.stringify(p,null,2)+'\n'); process.exit(10);\"" || rc=$?
  return $rc
}

#--- 4. Scaffold (first install only) or upgrade -------------------------------
if [[ ! -f "${SITE_DIR}/package.json" ]]; then
  log "Creating new Docusaurus site (classic template)..."
  as_doc "cd '$BASE_DIR' && npx --yes create-docusaurus@${DOC_VERSION} site classic --javascript --package-manager npm --skip-install"
  [[ -f "${SITE_DIR}/package.json" ]] || { err "Scaffolding failed."; exit 1; }

  # set the site URL once (edit docusaurus.config.* later for your real domain)
  for f in "${SITE_DIR}"/docusaurus.config.js "${SITE_DIR}"/docusaurus.config.ts; do
    [[ -f "$f" ]] && sed -i "s|url: 'https://your-docusaurus-site.example.com'|url: 'http://${SERVER_IP}:${PORT}'|" "$f"
  done

  pin_webpack || true
  log "Installing npm packages (a few minutes)..."
  as_doc "cd '$SITE_DIR' && npm install --no-fund --no-audit"
else
  PIN_RC=0; pin_webpack || PIN_RC=$?
  if [[ $PIN_RC -eq 10 ]]; then
    log "Pinning webpack below 5.106 and reinstalling packages..."
    as_doc "cd '$SITE_DIR' && rm -rf node_modules package-lock.json && npm install --no-fund --no-audit"
  fi
  CUR="$(as_doc "cd '$SITE_DIR' && node -p \"require('./node_modules/@docusaurus/core/package.json').version\"" 2>/dev/null || echo none)"
  if [[ "$CUR" != "$DOC_VERSION" ]]; then
    log "Switching Docusaurus ${CUR} -> ${DOC_VERSION}..."
    as_doc "cd '$SITE_DIR' && node -e \"
      const fs=require('fs'),p=JSON.parse(fs.readFileSync('package.json'));
      for (const k of ['dependencies','devDependencies'])
        for (const n in (p[k]||{})) if (n.startsWith('@docusaurus/')) p[k][n]='${DOC_VERSION}';
      fs.writeFileSync('package.json', JSON.stringify(p,null,2)+'\n');\""
    as_doc "cd '$SITE_DIR' && npm install --no-fund --no-audit"
  else
    log "Docusaurus ${CUR} already installed - keeping your site content"
  fi
fi

#--- 5. Build ---------------------------------------------------------------------
log "Building the site..."
as_doc "cd '$SITE_DIR' && npm run build"
[[ -f "${SITE_DIR}/build/index.html" ]] || { err "Build failed - build/index.html missing."; exit 1; }

# helper for later content edits
cat > /usr/local/bin/docusaurus-rebuild <<EOF
#!/usr/bin/env bash
set -e
[[ \$EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
sudo -u docusaurus -H bash -c "cd '${SITE_DIR}' && npm run build"
echo "Rebuilt. Nginx serves ${SITE_DIR}/build"
EOF
chmod 755 /usr/local/bin/docusaurus-rebuild
chmod -R o+rX "${SITE_DIR}/build"

#--- 6. Nginx -------------------------------------------------------------------
log "Configuring Nginx on port ${PORT}..."
cat > "$NGINX_CONF" <<EOF
server {
    listen ${PORT};
    listen [::]:${PORT};
    server_name _;
    root ${SITE_DIR}/build;
    index index.html;

    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml text/plain application/xml;

    location /assets/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files \$uri =404;
    }
    location / {
        try_files \$uri \$uri/ =404;
    }
    error_page 404 /404.html;
}
EOF
ln -sfn "$NGINX_CONF" /etc/nginx/sites-enabled/docusaurus
[[ "$PORT" == "80" ]] && rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 || { nginx -t; err "Nginx config test failed."; exit 1; }
systemctl enable --now nginx >/dev/null 2>&1
systemctl reload nginx

#--- 7. Health ------------------------------------------------------------------
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" || true)"
[[ "$CODE" == "200" ]] || { err "Site returned HTTP ${CODE}. Check: tail /var/log/nginx/error.log"; exit 1; }

echo
echo "========== Docusaurus ${DOC_VERSION} RUNNING =========="
echo "URL       : http://${SERVER_IP}:${PORT}"
echo "Login     : none (static site)"
echo "Site dir  : ${SITE_DIR}   (edit docs/, blog/, src/, docusaurus.config.js)"
echo "Rebuild   : sudo docusaurus-rebuild"
echo "Behind a domain: set 'url' (and 'baseUrl') in ${SITE_DIR}/docusaurus.config.js,"
echo "then run: sudo docusaurus-rebuild"
echo "======================================================="
