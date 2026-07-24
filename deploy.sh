#!/usr/bin/env bash
# deploy.sh: one command to stand up vscode-web on a VM AND replicate this
# machine's full Claude Code setup onto it. Run from the machine whose ~/.claude
# is the golden source (the laptop you use every day).
#
#   ./deploy.sh user@host [domain]
#
# Everything else is auto-negotiated on the far side by deploy/autoconfig.sh:
# the front door, the docker network, the container, and the port. In integrate
# mode code-server runs as a container reached by name, so its port never touches
# the host and cannot collide with anything already running there. Extra config
# is read from a local .env if present (DEPLOY_TARGET, DOMAIN, DEPLOY_SSH_KEY,
# CONTAINER_NAME, NVIDIA_API_KEY). Secrets travel over scp only, never git.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[[ -f "${HERE}/.env" ]] && { set -a; source "${HERE}/.env"; set +a; }

TARGET="${1:-${DEPLOY_TARGET:-}}"
DOMAIN="${2:-${DOMAIN:-vscode.dmj.one}}"
CONTAINER_NAME="${CONTAINER_NAME:-vscode-web}"
[[ -n "${TARGET}" ]] || { echo "usage: ./deploy.sh user@host [domain]   (or set DEPLOY_TARGET in .env)"; exit 1; }
[[ -f "${HOME}/.claude/.credentials.json" ]] || { echo "ERROR: no ~/.claude/.credentials.json on this machine. Run 'claude' + login first."; exit 1; }

KEYOPT=(); [[ -n "${DEPLOY_SSH_KEY:-}" ]] && KEYOPT=(-i "${DEPLOY_SSH_KEY}")
SSH=(ssh "${KEYOPT[@]}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
SCP=(scp "${KEYOPT[@]}" -o StrictHostKeyChecking=accept-new)

echo "== deploy vscode-web -> ${TARGET}  (domain ${DOMAIN}, container ${CONTAINER_NAME}) =="

# 1. Bundle this machine's ~/.claude essentials (config + credential only; no
#    caches, no 400MB of session history). The credential rides inside the tar.
BUNDLE="$(mktemp -u)-claude-bundle.tgz"
( cd "${HOME}/.claude" && tar czf "${BUNDLE}" CLAUDE.md RTK.md reference skills settings.json .credentials.json 2>/dev/null )
BUNDLE_REMOTE="/tmp/$(basename "${BUNDLE}")"
trap 'rm -f "${BUNDLE}"' EXIT

# 2. Ship scripts + bundle, and write a minimal server-side .env for autoconfig.
echo "-- uploading scripts + config bundle --"
"${SCP[@]}" "${HERE}/deploy/autoconfig.sh" "${HERE}/deploy/replicate-claude-env.sh" "${BUNDLE}" "${TARGET}:/tmp/" >/dev/null
"${SSH[@]}" "${TARGET}" "umask 077; { echo DOMAIN=${DOMAIN}; echo CODE_SERVER_PORT=8080; echo CONTAINER_NAME=${CONTAINER_NAME}; ${NVIDIA_API_KEY:+echo NVIDIA_API_KEY=${NVIDIA_API_KEY};} } > ~/.env; cp /tmp/autoconfig.sh ~/vscode-web-autoconfig.sh"

# 3. Deploy code-server (auto-detects front door + network + port, non-disruptive).
echo "-- running autoconfig on the VM --"
"${SSH[@]}" "${TARGET}" "sudo bash ~/vscode-web-autoconfig.sh"

# 4. Replicate the full Claude environment INTO the container.
echo "-- replicating Claude setup into the container --"
"${SSH[@]}" "${TARGET}" "docker cp ${BUNDLE_REMOTE} ${CONTAINER_NAME}:/tmp/claude-bundle.tgz && docker cp /tmp/replicate-claude-env.sh ${CONTAINER_NAME}:/tmp/replicate-claude-env.sh && docker exec ${CONTAINER_NAME} bash /tmp/replicate-claude-env.sh"

# 5. Wipe the transferred secrets from the VM and container.
echo "-- cleaning up transferred secrets --"
"${SSH[@]}" "${TARGET}" "sudo rm -f ${BUNDLE_REMOTE} /tmp/replicate-claude-env.sh; docker exec ${CONTAINER_NAME} rm -f /tmp/claude-bundle.tgz /tmp/replicate-claude-env.sh 2>/dev/null || true"

echo ""
echo "== done =="
echo " Add the Cloudflare DNS record autoconfig printed above, then open https://${DOMAIN}"
echo " Log in with the code-server password (on the VM: grep CODE_SERVER_PASSWORD ~/.env),"
echo " open a terminal, run 'claude'. Your CLAUDE.md, 31 dmj skills, plugins, and the"
echo " Claude Code extension are already there."
