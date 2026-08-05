# CHANGELOG

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### 2026-08-05 - Multi-agent brain: one instruction set for any AI agent

**Added**
- `agents/`: makes the dmj conventions, tools, and models work in agents other than Claude Code (GitHub Copilot, Continue, Cline / Roo, Cursor), so the server can be driven by NVIDIA or DeepSeek models with the same discipline.
- `agents/AGENTS.md`: canonical cross-agent instruction set distilled from CLAUDE.md and the dmj skills (private financial details excluded; it is a public file). `setup-agents.sh` symlinks each agent's own instruction file to it, so one edit updates all.
- `agents/models.copilot.json`: VS Code Copilot custom OpenAI-compatible providers for NVIDIA (`integrate.api.nvidia.com`) and DeepSeek direct (`api.deepseek.com`: `deepseek-v4-flash` / V4-Flash-0731 and `deepseek-v4-pro`). Keys are `${input:...}` secret references, never committed.
- `agents/mcp.json`: portable MCP servers (context7, playwright) that carry across Claude, Cline, Continue, and Copilot.

### 2026-08-05 - Cloudflare Flexible support + self-healing Caddy site

**Fixed**
- Redirect loop behind Cloudflare Flexible mode. The site is served on http:// directly and never 308-redirected to https, so Cloudflare's origin fetch over :80 no longer loops. The https:// site with tls internal is kept for Full mode.
- The site, and a neighbor (workday), had been silently dropped from the shared Caddyfile by unrelated redeploys on the box.

**Added**
- `deploy/vscode-web-ensure.sh`: idempotent self-healer that re-adds the managed site(s) to the front-door Caddyfile whenever they go missing and reloads Caddy gracefully. Auto-detects the Caddy container and its Caddyfile. `--install` sets it up as a systemd path plus timer. Guards a list of `domain|upstream` sites from `/etc/vscode-web-ensure.sites`.
- `deploy.sh` installs the self-healer as part of every deploy, so a site stays up even on a box whose other tooling rewrites the shared Caddyfile.

### 2026-07-24 - Reusable one-command deploy + Claude environment replication

**Added**
- `deploy.sh`: one command (`./deploy.sh user@host [domain]`) that bundles this machine's `~/.claude`, ships it over SSH, runs autoconfig, and replicates the full Claude Code setup into the container. Secrets travel over scp and are wiped from the VM afterward; nothing personal enters the repo.
- `deploy/replicate-claude-env.sh`: idempotent in-container setup. Places CLAUDE.md, RTK.md, reference/, skills/, settings.json and the credential; adds the dmj (GitHub), caveman, and official plugin marketplaces and installs every enabled plugin; installs the `anthropic.claude-code` VS Code extension. Rewrites the dmj marketplace source from the laptop path to GitHub and drops laptop-only hooks.
- Dynamic port handling: integrate mode never binds a host port (the container is reached by name), and standalone mode walks to the first free host port, so a busy VM needs no manual port config.

### 2026-07-24 - Pivot: GCP to OCI, container-integrate behind an existing Caddy

**Changed**
- Deploy target moved from a GCloud VM to an OCI (Oracle Cloud) VM. Recommended zero-cost shape: Always-Free Ampere A1.Flex, up to 4 OCPU / 24 GB, always on. The author's current box is a paid E5.Flex (6 OCPU / 32 GB, x86), which is not always-free.
- Rewrote `deploy/autoconfig.sh` around a non-disruptive container-integrate. When a Caddy container already owns :443, autoconfig builds a small code-server image inline (code-server + Node 20 + Claude Code CLI + pnpm), runs it as its own container joined to that Caddy's docker network with no published host port, and points Caddy at it by container name. Before touching the live front door it backs up the Caddyfile, baselines every existing site's HTTP status, appends one site block, runs `caddy validate`, reloads gracefully from a copy pushed into the container (avoids a single-file bind-mount inode-staleness problem), and auto-rolls-back if any previously-healthy site regresses. Verified unchanged: sso.dmj.one, workday.dmj.one, testudaan.dmj.one.
- Domain is `vscode.dmj.one`, live and verified (code-server login redirect, HTTP 302, through the front door).
- TLS: Caddy uses `tls internal` behind Cloudflare Full mode. No public ACME on the box.
- Rewrote `README.md` and `.env.example` for the OCI + container-integrate architecture, the 2-step deploy, and the free-A1-vs-paid cost table.

**Added**
- Standalone greenfield mode in `autoconfig.sh`: when no front door owns :443, it runs code-server host-native under systemd on 127.0.0.1 and installs Caddy natively to serve the domain. Provided for a blank VM, not yet live-tested.
- Named docker volume `vscode-web-home` for `/home/coder`, so the workspace, extensions, config, and the `claude` login survive container restarts.

**Removed**
- The GCP provisioning script `deploy/create-vm.sh`. GCP is gone.
- The Docker scaffold files `deploy/Dockerfile` and `deploy/docker-compose.yml`. The code-server image is now built inline by `autoconfig.sh`, so the standalone scaffold was redundant. This is a scaffold cleanup, not a move away from containers: the primary integrate path runs code-server in a container.
- Nginx, UFW, and fail2ban from the deploy path. `autoconfig.sh` no longer touches the host firewall, so a redeploy cannot disrupt the box.

### Earlier entries (initial GCP scaffold, superseded by the 2026-07-24 pivot)

**Added**
- `deploy/create-vm.sh`: idempotent GCloud VM provisioning (e2-standard-2, us-central1-a, firewall 80/443)
- `deploy/autoconfig.sh`: idempotent VM bootstrap (code-server + Node 20 + Claude Code + Nginx + UFW + fail2ban, Argon2id password, TLS, health check)
- `deploy/Dockerfile` + `docker-compose.yml`: local parity environment for code-server
- `.env.example`: all configuration (password, NVIDIA_API_KEY, Claude token, domain, VM sizing)
- `README.md`: end-to-end deploy guide, cost table, 10-agent workflow, NVIDIA model usage
- `.gitignore`: secrets and local artifacts excluded
