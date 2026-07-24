#!/usr/bin/env bash
# replicate-claude-env.sh: run INSIDE the code-server container to make its
# Claude Code identical to the author's laptop: personal config, plugins,
# credential, and the VS Code extension. Idempotent, safe to rerun.
#
# Inputs (all optional, deploy.sh provides them):
#   ~/.claude/*                 config already placed by deploy.sh (CLAUDE.md,
#                               RTK.md, reference/, skills/, settings.json), OR
#   CLAUDE_BUNDLE=/path.tgz     a tar of those to unpack (default /tmp/claude-bundle.tgz)
#   CLAUDE_CREDENTIALS_B64=...   base64 of ~/.claude/.credentials.json
#
# The personal config and credential are NEVER baked into this script or the
# repo; they arrive at runtime. This script is the generic, public part.

set -uo pipefail
CLAUDE_HOME="${HOME}/.claude"
mkdir -p "${CLAUDE_HOME}"

echo "== replicate-claude-env @ $(whoami) =="

# 1. Unpack a config bundle if one was shipped in.
BUNDLE="${CLAUDE_BUNDLE:-/tmp/claude-bundle.tgz}"
if [[ -f "${BUNDLE}" ]]; then
  tar xzf "${BUNDLE}" -C "${CLAUDE_HOME}" && echo "unpacked config bundle"
fi

# 2. Write the credential from env if provided (else assume it is already placed).
if [[ -n "${CLAUDE_CREDENTIALS_B64:-}" ]]; then
  echo "${CLAUDE_CREDENTIALS_B64}" | base64 -d > "${CLAUDE_HOME}/.credentials.json" && echo "wrote .credentials.json from env"
fi
[[ -f "${CLAUDE_HOME}/.credentials.json" ]] && chmod 600 "${CLAUDE_HOME}/.credentials.json"

# 3. Adjust settings.json for a Linux server: point the dmj marketplace at GitHub
#    (the laptop uses a Windows directory path) and drop laptop-only hooks (rtk).
if [[ -f "${CLAUDE_HOME}/settings.json" ]] && command -v node >/dev/null 2>&1; then
  node -e '
    const fs = require("fs"), p = process.env.HOME + "/.claude/settings.json";
    const s = JSON.parse(fs.readFileSync(p, "utf8"));
    s.extraKnownMarketplaces = s.extraKnownMarketplaces || {};
    s.extraKnownMarketplaces.dmj = { source: { source: "github", repo: "divyamohan1993/dmjcustomizations" } };
    if (s.hooks) delete s.hooks;               // rtk is a laptop-only binary
    fs.writeFileSync(p, JSON.stringify(s, null, 2));
  ' && echo "adjusted settings.json for server (dmj->github, hooks dropped)"
fi

# 4. Add the marketplaces the laptop uses, then install every plugin it enables.
add_mkt() { claude plugin marketplace add "$1" >/dev/null 2>&1 && echo "  marketplace + $1" || echo "  marketplace ~ $1 (already/failed)"; }
add_mkt divyamohan1993/dmjcustomizations
add_mkt JuliusBrussee/caveman
add_mkt anthropics/claude-plugins-official

if [[ -f "${CLAUDE_HOME}/settings.json" ]] && command -v node >/dev/null 2>&1; then
  mapfile -t SPECS < <(node -e '
    const s = require(process.env.HOME + "/.claude/settings.json");
    for (const [k, v] of Object.entries(s.enabledPlugins || {})) if (v === true) console.log(k);
  ')
  for spec in "${SPECS[@]}"; do
    claude plugin install "${spec}" >/dev/null 2>&1 && echo "  plugin + ${spec}" || echo "  plugin ~ ${spec} (already/failed)"
  done
fi

# 5. Install the Claude Code VS Code extension into code-server (OpenVSX).
#    If it is not on OpenVSX, running `claude` in a terminal installs the
#    companion extension itself, so this is best-effort.
if command -v code-server >/dev/null 2>&1; then
  if code-server --install-extension anthropic.claude-code >/dev/null 2>&1; then
    echo "  extension + anthropic.claude-code"
  else
    echo "  extension ~ anthropic.claude-code not on OpenVSX; run 'claude' in a terminal to install it, or side-load the VSIX"
  fi
fi

# 6. Report.
echo "== verify =="
echo "  claude: $(claude --version 2>&1 | head -1)"
echo "  marketplaces:"; claude plugin marketplace list 2>&1 | grep -iE 'dmj|caveman|official' | sed 's/^/    /' | head
echo "  plugins:"; claude plugin list 2>&1 | sed 's/^/    /' | head -25
echo "== done: open a code-server terminal and run 'claude' =="
