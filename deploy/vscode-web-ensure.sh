#!/usr/bin/env bash
# vscode-web-ensure.sh: keep one or more sites alive in a shared Caddyfile that
# OTHER deploys on the box rewrite (they drop any block they do not own, which is
# how vscode.dmj.one and workday.dmj.one kept vanishing). Idempotent: adds the
# blocks only when missing or not loaded, then reloads Caddy gracefully. Safe on
# a systemd path-trigger and/or timer.
#
# Cloudflare Flexible friendly: each http:// site is SERVED, never 308-redirected
# to https, so Cloudflare's origin fetch over :80 cannot loop. Each https:// site
# carries `tls internal`, so Full mode also works.
#
# Sites come from ${SITES_FILE:-/etc/vscode-web-ensure.sites}, one "domain|upstream"
# per line (# comments allowed). Defaults to vscode.dmj.one|vscode-web:8080.

set -uo pipefail
SITES_FILE="${SITES_FILE:-/etc/vscode-web-ensure.sites}"
command -v docker >/dev/null 2>&1 || { echo "docker not found"; exit 0; }
# Auto-detect the front-door Caddy container (the one publishing :443) and the
# host path of its mounted Caddyfile, so this works on any box, not only this one.
CADDY="${CADDY_CONTAINER:-$(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | awk -F'|' '/:443->/{print $1; exit}')}"
{ [[ -n "${CADDY}" ]] && docker inspect "${CADDY}" >/dev/null 2>&1; } || { echo "no caddy container publishing :443"; exit 0; }
CF="${CADDYFILE_PATH:-$(docker inspect "${CADDY}" --format '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)}"
[[ -f "${CF}" ]] || { echo "no mounted Caddyfile for ${CADDY}"; exit 0; }

# --install [domain] [upstream]: install THIS script as a self-healing systemd
# path+timer, register the site, and run once. Run as root. Used by deploy.sh so
# every deploy stays up even when other tooling rewrites the shared Caddyfile.
if [[ "${1:-}" == "--install" ]]; then
  D="${2:-${DOMAIN:-vscode.dmj.one}}"; U="${3:-vscode-web:8080}"
  install -m 755 "$0" /usr/local/bin/vscode-web-ensure.sh
  touch "${SITES_FILE}"
  grep -qF "${D}|" "${SITES_FILE}" || echo "${D}|${U}" >> "${SITES_FILE}"
  cat > /etc/systemd/system/vscode-web-ensure.service <<'U1'
[Unit]
Description=Ensure vscode-web Caddy sites present
After=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vscode-web-ensure.sh
U1
  cat > /etc/systemd/system/vscode-web-ensure.path <<U2
[Unit]
Description=Re-add vscode-web sites when the shared Caddyfile changes
[Path]
PathModified=${CF}
PathChanged=${CF}
Unit=vscode-web-ensure.service
[Install]
WantedBy=multi-user.target
U2
  cat > /etc/systemd/system/vscode-web-ensure.timer <<'U3'
[Unit]
Description=Periodically ensure vscode-web sites
[Timer]
OnBootSec=60
OnUnitActiveSec=300
[Install]
WantedBy=timers.target
U3
  systemctl daemon-reload
  systemctl enable --now vscode-web-ensure.path vscode-web-ensure.timer >/dev/null 2>&1 || true
  echo "self-healer installed for ${D}|${U}"
  exec /usr/local/bin/vscode-web-ensure.sh
fi

declare -a SITES=()
if [[ -f "${SITES_FILE}" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [[ -n "${line}" && "${line}" == *"|"* ]] && SITES+=("${line}")
  done < "${SITES_FILE}"
fi
[[ ${#SITES[@]} -eq 0 ]] && SITES=("vscode.dmj.one|vscode-web:8080")

# Fast path: every domain present in the file AND in the running config -> done.
need=0
for s in "${SITES[@]}"; do
  grep -qF ">>> vscode-web managed: ${s%%|*}" "${CF}" || { need=1; break; }
done
if [[ ${need} -eq 0 ]]; then
  running="$(docker exec "${CADDY}" wget -qO- http://127.0.0.1:2019/config/ 2>/dev/null)"
  for s in "${SITES[@]}"; do echo "${running}" | grep -q "${s%%|*}" || { need=1; break; }; done
fi
[[ ${need} -eq 0 ]] && exit 0

echo "$(date -u +%FT%TZ) (re)adding managed sites: ${SITES[*]}"
cp -a "${CF}" "${CF}.bak.vscode-web.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
ls -1t "${CF}".bak.vscode-web.* 2>/dev/null | tail -n +8 | xargs -r rm -f   # keep last 7 backups

# Rebuild in a temp file, then write back IN PLACE (preserve inode: a single-file
# docker bind mount follows the inode, so mv/sed -i would desync the container).
NEW="$(mktemp)"
sed "/>>> vscode-web managed:/,/<<< vscode-web managed:/d" "${CF}" > "${NEW}"
for s in "${SITES[@]}"; do
  d="${s%%|*}"; u="${s##*|}"; snip="vscodeweb_$(echo "${d}" | tr '.-' '_')"
  cat >> "${NEW}" <<EOF

# >>> vscode-web managed: ${d} >>>
(${snip}) {
    encode zstd gzip
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options    "nosniff"
        X-Frame-Options           "SAMEORIGIN"
        Referrer-Policy           "strict-origin-when-cross-origin"
        -Server
    }
    reverse_proxy ${u} {
        header_up -CF-Connecting-IP
    }
}
http://${d} {
    import ${snip}
}
https://${d} {
    tls internal
    import ${snip}
}
# <<< vscode-web managed: ${d} <<<
EOF
done
cat "${NEW}" > "${CF}"; rm -f "${NEW}"

docker cp "${CF}" "${CADDY}:/tmp/vscode-web-caddyfile" >/dev/null 2>&1
if docker exec "${CADDY}" caddy validate --config /tmp/vscode-web-caddyfile --adapter caddyfile >/dev/null 2>&1; then
  docker exec "${CADDY}" caddy reload --config /tmp/vscode-web-caddyfile --adapter caddyfile
  echo "$(date -u +%FT%TZ) ensured ${#SITES[@]} site(s), caddy reloaded"
else
  echo "$(date -u +%FT%TZ) caddy validate FAILED, not reloading" >&2; exit 1
fi
