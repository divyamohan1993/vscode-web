# CHANGELOG

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
