#!/usr/bin/env bash
# autoconfig.sh: Put VS Code (code-server) in the browser on a host, behind
# whatever already fronts :80/:443, WITHOUT disrupting a single existing site.
#
# Two modes, auto-detected:
#
#   integrate  : a Caddy container already owns :443 (the common self-host / OCI
#                case). code-server runs as ITS OWN container joined to that
#                Caddy's docker network, and Caddy reaches it by name, exactly
#                like the box's other proxied apps. This deliberately does NOT
#                bind a host port and does NOT touch the host firewall: many
#                hardened hosts REJECT docker->host traffic except on a
#                whitelist (seen in the wild as INPUT ... -j REJECT
#                icmp-host-prohibited), so a host-native upstream would 502.
#                A container on the same bridge is the only non-invasive path.
#                We APPEND one site block to the Caddyfile, `caddy validate`,
#                graceful `caddy reload`, back up first, baseline every existing
#                site, and AUTO-ROLL-BACK if any healthy site regresses.
#
#   standalone : no front door found (a blank VM). code-server runs host-native
#                under systemd on 127.0.0.1, and we install Caddy natively to
#                serve ${DOMAIN}. (Greenfield convenience path; not exercised on
#                the dmj box.)
#
# Never: installs Nginx, runs `apt upgrade`, edits the host firewall, or touches
# any container/site other than code-server's own. Idempotent: rerun freely.
#
# Usage (on the VM):  sudo bash autoconfig.sh
#
# .env (loaded from ./, /home/ubuntu, or /root):
#   CODE_SERVER_PASSWORD    login password (blank -> one is generated + saved once)
#   DOMAIN                  public hostname (default vscode.dmj.one)
#   NVIDIA_API_KEY          optional; passed into the code-server environment
#   CLAUDE_CODE_OAUTH_TOKEN optional; pre-auths the `claude` CLI inside
#   CODE_SERVER_PORT        code-server's internal port (default 8080)
#   CONTAINER_NAME          integrate mode container name (default vscode-web)
#   FRONT_NET               override the docker network to join (default: the
#                           front-door container's network)
#   CADDY_CONTAINER         override the front-door container (default: auto)
#   CADDYFILE_PATH          override the Caddyfile host path (default: the mount)
#   CODE_SERVER_USER        standalone mode only: user to run as (default: caller)
#   NODE_VERSION            standalone mode only: Node major (default 20)

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then echo "ERROR: run with sudo:  sudo bash $0" >&2; exit 1; fi

TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/vscode-web-autoconfig-${TS}.log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "=== vscode-web autoconfig @ ${TS} ==="

# --- load .env ---
SUDO_HOME="$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"
for cand in "./.env" "${SUDO_HOME}/.env" "/home/ubuntu/.env" "/root/.env"; do
  [[ -f "${cand}" ]] && { ENV_FILE="${cand}"; break; }
done
if [[ -n "${ENV_FILE:-}" ]]; then
  echo "Loading env from ${ENV_FILE}"
  set -a; # shellcheck disable=SC1090
  source "${ENV_FILE}"; set +a
else
  ENV_FILE="${SUDO_HOME}/.env"
fi

DOMAIN="${DOMAIN:-vscode.dmj.one}"
CODE_SERVER_PORT="${CODE_SERVER_PORT:-8080}"
CONTAINER_NAME="${CONTAINER_NAME:-vscode-web}"
IMAGE="vscode-web:local"
echo "Domain=${DOMAIN}  Container=${CONTAINER_NAME}  Port=${CODE_SERVER_PORT}"

# --- detect front door ---
MODE="standalone"
CADDY_CONTAINER="${CADDY_CONTAINER:-}"
if command -v docker >/dev/null 2>&1; then
  [[ -z "${CADDY_CONTAINER}" ]] && CADDY_CONTAINER="$(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | awk -F'|' '/:443->/{print $1; exit}')"
  [[ -n "${CADDY_CONTAINER}" ]] && docker inspect "${CADDY_CONTAINER}" >/dev/null 2>&1 && MODE="integrate"
fi
echo "Front-door mode: ${MODE}${CADDY_CONTAINER:+ (container=${CADDY_CONTAINER})}"

# --- password (generate + persist once) ---
if [[ -z "${CODE_SERVER_PASSWORD:-}" ]]; then
  command -v openssl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq openssl >/dev/null; }
  CODE_SERVER_PASSWORD="$(openssl rand -base64 24)"
  echo "  Generated password (saved once to ${ENV_FILE}):"
  echo "      ${CODE_SERVER_PASSWORD}"
  touch "${ENV_FILE}"; chmod 600 "${ENV_FILE}"
  grep -q '^CODE_SERVER_PASSWORD=' "${ENV_FILE}" 2>/dev/null || echo "CODE_SERVER_PASSWORD=${CODE_SERVER_PASSWORD}" >> "${ENV_FILE}"
fi

site_check() { curl -sk -o /dev/null -w '%{http_code}' --resolve "$1:443:127.0.0.1" --max-time 8 "https://$1/" 2>/dev/null || echo 000; }

# =====================================================================
if [[ "${MODE}" == "integrate" ]]; then
  # ---- remove any earlier host-native code-server from a prior run ----
  if systemctl list-unit-files 2>/dev/null | grep -q '^code-server.service'; then
    echo "Removing prior host-native code-server service (superseded by container)..."
    systemctl disable --now code-server 2>/dev/null || true
    rm -f /etc/systemd/system/code-server.service
    systemctl daemon-reload 2>/dev/null || true
  fi

  # ---- the docker network Caddy lives on (join it so Caddy resolves us) ----
  if [[ -z "${FRONT_NET:-}" ]]; then
    FRONT_NET="$(docker inspect "${CADDY_CONTAINER}" --format '{{range $n,$v := .NetworkSettings.Networks}}{{$n}} {{end}}' | awk '{print $1}')"
  fi
  [[ -n "${FRONT_NET}" ]] || { echo "ERROR: could not determine ${CADDY_CONTAINER}'s network." >&2; exit 1; }
  echo "[1/4] code-server will join docker network: ${FRONT_NET}"

  # ---- build the image (code-server + Node 20 + Claude Code), only if missing ----
  echo "[2/4] Ensuring image ${IMAGE} (code-server + Node 20 + Claude Code)..."
  if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    BUILD_DIR="$(mktemp -d)"
    cat > "${BUILD_DIR}/Dockerfile" <<'DOCKER'
# Pinned for reproducible rebuilds. Bump deliberately; codercom/code-server
# publishes a semver tag per release and is multi-arch (arm64 for A1, x86_64 for E5).
FROM codercom/code-server:4.130.0
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl git jq ca-certificates build-essential python3 \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g @anthropic-ai/claude-code pnpm \
 && rm -rf /var/lib/apt/lists/*
USER coder
DOCKER
    docker build -t "${IMAGE}" "${BUILD_DIR}"
    rm -rf "${BUILD_DIR}"
  else
    echo "  image present."
  fi

  # ---- (re)create the container on the front-door network, no host port ----
  echo "[3/4] Starting container ${CONTAINER_NAME} on ${FRONT_NET}..."
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  RUN_ENV=(-e "PASSWORD=${CODE_SERVER_PASSWORD}")
  [[ -n "${NVIDIA_API_KEY:-}" ]]          && RUN_ENV+=(-e "NVIDIA_API_KEY=${NVIDIA_API_KEY}")
  [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && RUN_ENV+=(-e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}")
  docker run -d --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    --network "${FRONT_NET}" \
    "${RUN_ENV[@]}" \
    -v vscode-web-home:/home/coder \
    "${IMAGE}" >/dev/null

  # ---- wait until Caddy can actually reach it by name ----
  echo "  waiting for ${CONTAINER_NAME}:${CODE_SERVER_PORT} from Caddy..."
  CS_UP=""
  for i in $(seq 1 30); do
    if docker exec "${CADDY_CONTAINER}" sh -c "wget -q -T3 -O- http://${CONTAINER_NAME}:${CODE_SERVER_PORT}/healthz >/dev/null 2>&1 || wget -q -T3 -O- http://${CONTAINER_NAME}:${CODE_SERVER_PORT}/ >/dev/null 2>&1"; then
      CS_UP=1; echo "  reachable."; break
    fi
    sleep 2
  done
  [[ -z "${CS_UP}" ]] && { echo "ERROR: Caddy cannot reach ${CONTAINER_NAME}; front door untouched." >&2; docker logs --tail 30 "${CONTAINER_NAME}" || true; exit 1; }

  # ---- append the Caddy site (backup, strip old managed block, validate, reload) ----
  echo "[4/4] Adding the ${DOMAIN} site to Caddy (${CADDY_CONTAINER})..."
  [[ -z "${CADDYFILE_PATH:-}" ]] && CADDYFILE_PATH="$(docker inspect "${CADDY_CONTAINER}" --format '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}')"
  [[ -f "${CADDYFILE_PATH}" ]] || { echo "ERROR: mounted Caddyfile not found (${CADDYFILE_PATH:-unset})." >&2; exit 1; }
  echo "  Caddyfile: ${CADDYFILE_PATH}"

  mapfile -t PRE_HOSTS < <(sed '/>>> vscode-web managed:/,/<<< vscode-web managed:/d' "${CADDYFILE_PATH}" \
    | grep -oE 'https?://[A-Za-z0-9][A-Za-z0-9.-]+\.[A-Za-z]{2,}' | sed -E 's#https?://##' | sort -u | grep -vx "${DOMAIN}" || true)
  declare -A PRE_CODE
  echo "  baseline of existing sites:"
  for h in "${PRE_HOSTS[@]}"; do PRE_CODE["$h"]="$(site_check "$h")"; echo "    ${h} -> ${PRE_CODE[$h]}"; done

  BACKUP="${CADDYFILE_PATH}.bak.vscode-web.${TS}"
  cp -a "${CADDYFILE_PATH}" "${BACKUP}"; echo "  backup: ${BACKUP}"
  # A single-file docker bind mount follows the INODE. `sed -i` / `mv` swap the
  # inode and silently desync the running Caddy from the file on disk, so we
  # build the new content in a temp file and truncate-rewrite the SAME inode
  # (cat > file). And because the live mount may ALREADY be stale, we validate
  # and reload Caddy from a copy pushed into the container, not the mounted path.
  NEWCF="$(mktemp)"
  sed '/>>> vscode-web managed:/,/<<< vscode-web managed:/d' "${CADDYFILE_PATH}" > "${NEWCF}"
  cat >> "${NEWCF}" <<EOF

# >>> vscode-web managed: ${DOMAIN} >>>
# Added by vscode-web/deploy/autoconfig.sh. Mirrors the box's other proxied
# containers: reach code-server by container name on the shared docker network,
# tls internal (Cloudflare Full mode). Remove this block to detach the site.
(vscode_web_site) {
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options    "nosniff"
		X-Frame-Options           "SAMEORIGIN"
		Referrer-Policy           "strict-origin-when-cross-origin"
		-Server
	}
	reverse_proxy ${CONTAINER_NAME}:${CODE_SERVER_PORT} {
		header_up -CF-Connecting-IP
	}
}

http://${DOMAIN} {
	import vscode_web_site
}

https://${DOMAIN} {
	tls internal
	import vscode_web_site
}
# <<< vscode-web managed: ${DOMAIN} <<<
EOF
  cat "${NEWCF}" > "${CADDYFILE_PATH}"; rm -f "${NEWCF}"   # write back in place (same inode)

  # Validate + reload from a copy pushed into the container, so a stale single-
  # file bind mount can never desync the running Caddy from what we just wrote.
  cf_reload() {
    docker cp "${CADDYFILE_PATH}" "${CADDY_CONTAINER}:/tmp/vscode-web-caddyfile" >/dev/null 2>&1
    docker exec "${CADDY_CONTAINER}" caddy "$1" --config /tmp/vscode-web-caddyfile --adapter caddyfile
  }
  if ! cf_reload validate >/tmp/vscode-web-validate.log 2>&1; then
    echo "ERROR: caddy validate FAILED. Restoring Caddyfile (no reload happened)." >&2
    cat /tmp/vscode-web-validate.log >&2; cat "${BACKUP}" > "${CADDYFILE_PATH}"; exit 1
  fi
  echo "  validate OK. Reloading Caddy (graceful)..."
  cf_reload reload

  echo "  re-checking existing sites:"
  REGRESSED=""
  for h in "${PRE_HOSTS[@]}"; do
    now="$(site_check "$h")"; echo "    ${h}: ${PRE_CODE[$h]} -> ${now}"
    # regression = was healthy (2xx/3xx), now is not.
    [[ "${PRE_CODE[$h]}" =~ ^[23] && ! "${now}" =~ ^[23] ]] && REGRESSED="${REGRESSED} ${h}"
  done
  if [[ -n "${REGRESSED}" ]]; then
    echo "ERROR: regression on:${REGRESSED}, rolling back Caddyfile + reload." >&2
    cat "${BACKUP}" > "${CADDYFILE_PATH}"; cf_reload reload || true
    exit 1
  fi
  NEW_CODE="$(site_check "${DOMAIN}")"; echo "  ${DOMAIN} via Caddy -> HTTP ${NEW_CODE}"

# =====================================================================
else
  # ---- standalone: host-native code-server + native Caddy (blank VM) ----
  CODE_SERVER_USER="${CODE_SERVER_USER:-${SUDO_USER:-ubuntu}}"
  NODE_VERSION="${NODE_VERSION:-20}"
  CS_HOME="$(getent passwd "${CODE_SERVER_USER}" | cut -d: -f6)"
  export DEBIAN_FRONTEND=noninteractive
  echo "[1/4] Installing packages (targeted)..."; apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg jq git openssl >/dev/null
  echo "[2/4] Installing code-server + Node ${NODE_VERSION} + Claude Code..."
  command -v code-server >/dev/null 2>&1 || curl -fsSL https://code-server.dev/install.sh | sh
  if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | sed 's/v//;s/\..*//')" -lt "${NODE_VERSION}" ]]; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -; apt-get install -y -qq nodejs >/dev/null
  fi
  command -v claude >/dev/null 2>&1 || npm install -g @anthropic-ai/claude-code
  install -d -m 700 -o "${CODE_SERVER_USER}" -g "${CODE_SERVER_USER}" "${CS_HOME}/.config/code-server"
  cat > "${CS_HOME}/.config/code-server/config.yaml" <<EOF
bind-addr: 127.0.0.1:${CODE_SERVER_PORT}
auth: password
password: ${CODE_SERVER_PASSWORD}
cert: false
EOF
  chmod 600 "${CS_HOME}/.config/code-server/config.yaml"; chown "${CODE_SERVER_USER}:${CODE_SERVER_USER}" "${CS_HOME}/.config/code-server/config.yaml"
  cat > /etc/systemd/system/code-server.service <<EOF
[Unit]
Description=code-server (VS Code in the browser)
After=network-online.target
Wants=network-online.target
[Service]
User=${CODE_SERVER_USER}
WorkingDirectory=${CS_HOME}
Environment=NODE_OPTIONS=--max-old-space-size=4096
EnvironmentFile=-${ENV_FILE}
ExecStart=/usr/bin/code-server --config ${CS_HOME}/.config/code-server/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable code-server >/dev/null 2>&1 || true; systemctl restart code-server
  echo "[3/4] Installing standalone Caddy for ${DOMAIN}..."
  if ! command -v caddy >/dev/null 2>&1; then
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https >/dev/null
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq && apt-get install -y -qq caddy >/dev/null
  fi
  cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
	tls internal
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	reverse_proxy 127.0.0.1:${CODE_SERVER_PORT}
}
EOF
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  systemctl enable caddy >/dev/null 2>&1 || true; systemctl reload caddy 2>/dev/null || systemctl restart caddy
  echo "[4/4] done."; NEW_CODE="$(site_check "${DOMAIN}")"; echo "  ${DOMAIN} -> HTTP ${NEW_CODE}"
fi

# --- summary ---
PUB_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
echo ""
echo "============================================================"
echo " code-server is live behind ${DOMAIN}  (mode: ${MODE})"
echo " log: ${LOG_FILE}"
echo "============================================================"
echo " NEXT: add the Cloudflare DNS record (you do this, manually):"
echo "     A   ${DOMAIN%%.*}   ${PUB_IP}   Proxy ON (orange)   SSL/TLS: Full"
echo " Then open https://${DOMAIN} and log in with CODE_SERVER_PASSWORD."
echo "============================================================"
