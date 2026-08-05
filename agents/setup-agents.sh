#!/usr/bin/env bash
# setup-agents.sh: make every AI coding agent in a workspace share one brain.
# Drops AGENTS.md into the target repo and points each agent's own instruction
# file at it (symlink, with a copy fallback), then stages the MCP + Copilot model
# configs for you to load. Idempotent, safe to rerun.
#
# Usage:  ./agents/setup-agents.sh [target-dir]      (default: current directory)

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$(cd "${1:-$PWD}" && pwd)"
cd "${TARGET}"
echo "== wiring dmj agent brain into ${TARGET} =="

cp "${HERE}/AGENTS.md" ./AGENTS.md

# Point each agent's instruction file at AGENTS.md. Symlink so one edit updates
# all; fall back to a copy where symlinks are not honored.
link() { # link <path> <relative-target>
  local path="$1" rel="$2"
  mkdir -p "$(dirname "${path}")"
  rm -f "${path}"
  ln -s "${rel}" "${path}" 2>/dev/null || cp "${HERE}/AGENTS.md" "${path}"
  echo "  + ${path}"
}
link "CLAUDE.md"                        "AGENTS.md"     # Claude Code
link ".github/copilot-instructions.md"  "../AGENTS.md"  # GitHub Copilot
link ".clinerules"                      "AGENTS.md"     # Cline
link ".roorules"                        "AGENTS.md"     # Roo
link ".continue/rules/dmj.md"           "../../AGENTS.md" # Continue
link ".cursor/rules/dmj.mdc"            "../../AGENTS.md" # Cursor

# Stage the shared configs (you load these into the editor; see agents/README.md).
cp "${HERE}/mcp.json" ./mcp.json
cp "${HERE}/models.copilot.json" ./models.copilot.json
echo "  + mcp.json  + models.copilot.json"

echo ""
echo "== done. Next (see agents/README.md): =="
echo "  1. Copilot models: paste models.copilot.json into VS Code setting"
echo "     github.copilot.chat.customModels; it will prompt for each provider key once."
echo "  2. MCP: register mcp.json in each agent that speaks MCP."
echo "  3. Keys (NVIDIA, DeepSeek) go in the editor secret store, never in git."
