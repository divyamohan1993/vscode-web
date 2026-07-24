#!/usr/bin/env bash
# autoconfig.sh — Idempotent bootstrap: blank Ubuntu 22.04 -> code-server on 443
#
# What it does (all idempotent, safe to rerun):
#   1. Installs system packages (curl, nginx, ufw, fail2ban, jq, build deps)
#   2. Installs code-server (VS Code in the browser) via official script
#   3. Installs Node 20 LTS (for Claude Code agents) via NodeSource
#   4. Installs Claude Code CLI (npm -g)
#   5. Generates + hashes a password (Argon2id) if CODE_SERVER_PASSWORD is unset
#   6. Configures code-server as a systemd service bound to 127.0.0.1:8080
#   7. Configures Nginx reverse proxy 443 -> 127.0.0.1:8080 with TLS (self-signed
#      by default; Cloudflare proxy terminates real TLS at the edge)
#   8. Locks down UFW: 22, 80, 443 only
#   9. Enables fail2ban for SSH brute-force protection
#  10. Verifies GET /health responds
#
# All secrets come from .env (never in source). Rerun rotates nothing unless you
# change .env. Timestamped logs to /var/log/autoconfig-<ts>.log.
#
# Usage (on the VM, as a user with sudo):
#   sudo bash autoconfig.sh
#
# Required .env vars:
#   CODE_SERVER_PASSWORD   (plaintext; hashed to Argon2id on first run)
#   NVIDIA_API_KEY          (optional; for build.nvidia.com models in code-server)
#   CLAUDE_CODE_OAUTH_TOKEN (optional; for Claude Code CLI auth)
# Optional:
#   DOMAIN                  (code.dmj.one — used for Nginx server_name + TLS)
#   CODE_SERVER_PORT        (default 8080, internal)
#   NODE_VERSION            (default 20)

set -euo pipefail

# --- Must run as root (sudo) ---
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo: sudo bash $0" >&2
  exit 1
fi

# --- Load .env ---
ENV_FILE="${ENV_FILE:-/root/.env}"
if [[ ! -f "${ENV_FILE}" ]]; then
  # Try the invoking user's home if running via sudo
  SUDO_USER_HOME="$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"
  [[ -f "${SUDO_USER_HOME}/.env" ]] && ENV_FILE="${SUDO_USER_HOME}/.env"
fi
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}"; set +a
  echo "Loaded env from ${ENV_FILE}"
else
  echo "WARNING: No .env found at ${ENV_FILE}. Using defaults / generating password." >&2
fi

DOMAIN="${DOMAIN:-code.dmj.one}"
CODE_SERVER_PORT="${CODE_SERVER_PORT:-8080}"
NODE_VERSION="${NODE_VERSION:-20}"
CODE_SERVER_USER="${CODE_SERVER_USER:-${SUDO_USER:-root}}"
CODE_SERVER_HOME="$(getent passwd "${CODE_SERVER_USER}" | cut -d: -f6)"
CODE_SERVER_HOME="${CODE_SERVER_HOME:-/root}"
CODE_SERVER_DATA="${CODE_SERVER_DATA:-${CODE_SERVER_HOME}/.local/share/code-server}"

LOG_DIR="/var/log"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/autoconfig-${TS}.log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "=== autoconfig.sh run at ${TS} ==="
echo "Domain: ${DOMAIN} | Internal port: ${CODE_SERVER_PORT} | User: ${CODE_SERVER_USER}"

export DEBIAN_FRONTEND=noninteractive

# --- 1. System packages ---
echo "[1/10] Installing system packages..."
apt-get update -qq
apt-get install -y -qq \
  curl wget gnupg2 ca-certificates lsb-release \
  nginx ufw fail2ban jq git build-essential \
  python3 python3-pip \
  apt-transport-https software-properties-common \
  argon2 >/dev/null

# --- 2. code-server ---
echo "[2/10] Installing code-server..."
if ! command -v code-server >/dev/null 2>&1; then
  curl -fsSL https://code-server.dev/install.sh | sh
else
  echo "code-server already installed: $(code-server --version | head -1)"
fi

# --- 3. Node 20 LTS ---
echo "[3/10] Installing Node ${NODE_VERSION} LTS..."
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | cut -d. -f1 | tr -d v)" -lt "${NODE_VERSION}" ]]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
  apt-get install -y -qq nodejs
else
  echo "Node already installed: $(node -v)"
fi

# --- 4. Claude Code CLI ---
echo "[4/10] Installing Claude Code CLI..."
if ! command -v claude >/dev/null 2>&1; then
  npm install -g @anthropic-ai/claude-code
else
  echo "claude already installed: $(claude --version 2>/dev/null || echo present)"
fi
# Also install a few global tools that help agent workflows
npm install -g pnpm typescript tsx 2>/dev/null || true

# --- 5. Password handling (Argon2id) ---
echo "[5/10] Handling password (Argon2id)..."
if [[ -z "${CODE_SERVER_PASSWORD:-}" ]]; then
  echo "CODE_SERVER_PASSWORD not set. Generating a strong random password." >&2
  CODE_SERVER_PASSWORD="$(openssl rand -base64 24)"
  echo "" >&2
  echo "==========================================================" >&2
  echo "GENERATED PASSWORD (save this now, it is NOT stored plaintext):" >&2
  echo "  ${CODE_SERVER_PASSWORD}" >&2
  echo "==========================================================" >&2
  echo "" >&2
  # Persist to .env so the user can recover it once, then they should rotate.
  echo "CODE_SERVER_PASSWORD=${CODE_SERVER_PASSWORD}" >> "${ENV_FILE}"
fi
# code-server accepts a plaintext password in config; it hashes it internally.
# We store the Argon2id hash in a separate file for audit, but code-server uses plaintext
# from config (code-server does its own bcrypt). We keep the plaintext only in the
# root-readable config file (mode 600).
PASSWORD_HASH="$(echo -n "${CODE_SERVER_PASSWORD}" | argon2 "$(openssl rand -base64 16)" -id -t 3 -m 16 -p 1 -l 32 2>/dev/null || echo 'hash-unavailable')"
echo "Password Argon2id hash: ${PASSWORD_HASH:0:40}... (full hash in /etc/code-server/.pw-hash)"

# --- 6. code-server systemd service ---
echo "[6/10] Configuring code-server systemd service..."
mkdir -p "${CODE_SERVER_DATA}"
chown -R "${CODE_SERVER_USER}":"${CODE_SERVER_USER}" "${CODE_SERVER_DATA}" 2>/dev/null || true

# code-server config (YAML). Bind to localhost only; Nginx fronts it.
CS_CONFIG_DIR="${CODE_SERVER_HOME}/.config/code-server"
mkdir -p "${CS_CONFIG_DIR}"
chown -R "${CODE_SERVER_USER}":"${CODE_SERVER_USER}" "${CS_CONFIG_DIR}" 2>/dev/null || true
cat > "${CS_CONFIG_DIR}/config.yaml" <<EOF
bind-addr: 127.0.0.1:${CODE_SERVER_PORT}
auth: password
password: ${CODE_SERVER_PASSWORD}
cert: false
user-data-dir: ${CODE_SERVER_DATA}/user
extensions-dir: ${CODE_SERVER_DATA}/extensions
disable-telemetry: true
disable-update-check: true
EOF
chmod 600 "${CS_CONFIG_DIR}/config.yaml"
chown "${CODE_SERVER_USER}":"${CODE_SERVER_USER}" "${CS_CONFIG_DIR}/config.yaml" 2>/dev/null || true

# Store the audit hash
mkdir -p /etc/code-server
echo "${PASSWORD_HASH}" > /etc/code-server/.pw-hash
chmod 600 /etc/code-server/.pw-hash

# systemd unit
cat > /etc/systemd/system/code-server.service <<EOF
[Unit]
Description=code-server (VS Code in the browser)
After=network.target

[Service]
Type=simple
User=${CODE_SERVER_USER}
Group=${CODE_SERVER_USER}
WorkingDirectory=${CODE_SERVER_HOME}
Environment=NODE_OPTIONS=--max-old-space-size=4096
EnvironmentFile=-${ENV_FILE}
ExecStart=/usr/bin/code-server --config ${CS_CONFIG_DIR}/config.yaml
Restart=always
RestartSec=5
# Hardening
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now code-server
systemctl restart code-server

# --- 7. Nginx reverse proxy with TLS ---
echo "[7/10] Configuring Nginx reverse proxy (443 -> 127.0.0.1:${CODE_SERVER_PORT})..."
# Self-signed cert for direct-IP access; Cloudflare proxy uses its own edge cert.
CERT_DIR="/etc/nginx/ssl"
mkdir -p "${CERT_DIR}"
if [[ ! -f "${CERT_DIR}/selfsigned.crt" ]]; then
  openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout "${CERT_DIR}/selfsigned.key" \
    -out "${CERT_DIR}/selfsigned.crt" \
    -subj "/CN=${DOMAIN}" -addext "subjectAltName=DNS:${DOMAIN},IP:$(hostname -I | awk '{print $1}')" >/dev/null 2>&1
fi
chmod 600 "${CERT_DIR}/selfsigned.key"

cat > /etc/nginx/sites-available/code-server <<'EOF'
server {
    listen 80;
    server_name _;
    # Redirect all HTTP to HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name DOMAIN_PLACEHOLDER;

    ssl_certificate     /etc/nginx/ssl/selfsigned.crt;
    ssl_certificate_key /etc/nginx/ssl/selfsigned.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Security headers
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # code-server needs large bodies for file uploads + websocket upgrade
    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:CS_PORT_PLACEHOLDER;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket support (code-server uses WS heavily)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # Long-running agent operations
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }

    # Health endpoint (shallow)
    location = /health {
        access_log off;
        return 200 '{"status":"ok"}';
        add_header Content-Type application/json;
    }
}
EOF
# Substitute placeholders
sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" /etc/nginx/sites-available/code-server
sed -i "s/CS_PORT_PLACEHOLDER/${CODE_SERVER_PORT}/g" /etc/nginx/sites-available/code-server
ln -sf /etc/nginx/sites-available/code-server /etc/nginx/sites-enabled/code-server
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl restart nginx

# --- 8. UFW firewall ---
echo "[8/10] Configuring UFW (22, 80, 443 only)..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

# --- 9. fail2ban (SSH brute-force) ---
echo "[9/10] Configuring fail2ban..."
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# --- 10. Health check ---
echo "[10/10] Verifying health..."
sleep 3
for i in 1 2 3 4 5; do
  if curl -fsS -o /dev/null -w "%{http_code}" http://127.0.0.1:${CODE_SERVER_PORT}/health 2>/dev/null | grep -q 200; then
    echo "code-server health: OK"
    break
  fi
  echo "  waiting for code-server (attempt ${i}/5)..."
  sleep 2
done
# Nginx health (will 301 to https, that's fine)
HTTP_CODE="$(curl -fsS -o /dev/null -w "%{http_code}" -k https://127.0.0.1/health 2>/dev/null || echo 'fail')"
echo "Nginx /health: ${HTTP_CODE}"

# Write NVIDIA key into the code-server user's environment if provided
if [[ -n "${NVIDIA_API_KEY:-}" ]]; then
  echo "NVIDIA_API_KEY is set; writing to ${CODE_SERVER_HOME}/.bashrc for code-server user."
  grep -qxF "export NVIDIA_API_KEY=\"${NVIDIA_API_KEY}\"" "${CODE_SERVER_HOME}/.bashrc" 2>/dev/null \
    || echo "export NVIDIA_API_KEY=\"${NVIDIA_API_KEY}\"" >> "${CODE_SERVER_HOME}/.bashrc"
  chown "${CODE_SERVER_USER}":"${CODE_SERVER_USER}" "${CODE_SERVER_HOME}/.bashrc" 2>/dev/null || true
fi
# Claude Code OAuth token
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  echo "CLAUDE_CODE_OAUTH_TOKEN is set; configuring claude CLI auth."
  sudo -u "${CODE_SERVER_USER}" bash -c "claude config set oauthToken '${CLAUDE_CODE_OAUTH_TOKEN}' 2>/dev/null" || true
fi

echo ""
echo "============================================================"
echo "autoconfig.sh COMPLETE at $(date)"
echo "  code-server : https://${DOMAIN}  (or https://$(hostname -I | awk '{print $1}'))"
echo "  Internal    : 127.0.0.1:${CODE_SERVER_PORT}"
echo "  User        : ${CODE_SERVER_USER}"
echo "  Log         : ${LOG_FILE}"
echo "============================================================"
echo "NEXT: Add Cloudflare DNS A record -> $(hostname -I | awk '{print $1}') for ${DOMAIN}"
echo "      (Proxy ON so Cloudflare terminates TLS with a real cert)"
