# agents/: one brain, every agent

Your `~/.claude` setup makes **Claude Code** smart. Copilot, Continue, and Cline do not read
`~/.claude/`, so this folder makes the same conventions, tools, and models work in all of them.

Two things port across agents, by different means.

## 1. Conventions port by mirroring one file

`AGENTS.md` is the canonical instruction set (distilled from the dmj CLAUDE.md and skills).
`setup-agents.sh` drops it into a repo and points every agent's own file at it:

| Agent | File it reads | Wired to |
|---|---|---|
| Claude Code | `CLAUDE.md` | `AGENTS.md` |
| GitHub Copilot | `.github/copilot-instructions.md` | `AGENTS.md` |
| Cline | `.clinerules` | `AGENTS.md` |
| Roo | `.roorules` | `AGENTS.md` |
| Continue | `.continue/rules/dmj.md` | `AGENTS.md` |
| Cursor | `.cursor/rules/dmj.mdc` | `AGENTS.md` |
| Newer Copilot and others | `AGENTS.md` | itself |

They are symlinks to `AGENTS.md`, so editing `AGENTS.md` updates every agent at once. Run:

```bash
./agents/setup-agents.sh            # wire the current repo
./agents/setup-agents.sh /path/repo # or a specific one
```

Claude **skills** (the dmj ones) are invokable only inside Claude Code. Other agents cannot run
the skill machinery, but the important rules from those skills are already distilled into
`AGENTS.md`, so the discipline carries even where the machinery does not.

## 2. Capabilities port through MCP

`mcp.json` lists MCP servers (context7 for live docs, playwright for browser automation). MCP is
supported by Claude, Cline, Continue, and Copilot, so registering the same block in each agent
gives them all the same tools. Add servers here and they spread to every agent.

## 3. Models: NVIDIA and DeepSeek in Copilot

`models.copilot.json` defines custom OpenAI-compatible providers for VS Code Copilot (BYOK):

- **NVIDIA** (`integrate.api.nvidia.com`): GLM-5.2, DeepSeek V4 Pro, Kimi K2.6, Nemotron 3 Ultra, Kimi K3.
- **DeepSeek direct** (`api.deepseek.com`): `deepseek-v4-flash` (V4-Flash-0731, 1M in / 384K out) and `deepseek-v4-pro`.

Load it by pasting the array into the VS Code setting `github.copilot.chat.customModels`. Copilot
prompts once for each provider's key and stores it in the OS secret store. The `apiKey` fields
here are `${input:...}` **references**, not keys: no secret is ever committed. Get the keys from
[build.nvidia.com](https://build.nvidia.com) and [platform.deepseek.com](https://platform.deepseek.com).

## Secrets

Nothing in this folder is a secret. Keys live only in the editor's secret store or the VM `.env`,
never in git. `.env` is gitignored.
