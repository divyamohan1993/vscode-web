# vscode-web: VS Code in any browser, on an always-on VM

Close the laptop. The agents keep coding. vscode-web puts full VS Code in your browser on an always-on Oracle Cloud VM, ready for 10+ parallel Claude Code agents and NVIDIA build.nvidia.com models. Open it from a phone, a tablet, or a borrowed machine. The work does not stop because your hardware went to sleep.

Live now at https://vscode.dmj.one (code-server answers with its login redirect, HTTP 302, through the existing Caddy front door).

## One command

From the machine whose `~/.claude` is your daily setup:
```bash
./deploy.sh user@your-vm vscode.example.com
```
That is the whole instruction. `deploy.sh` bundles your `~/.claude` (config plus credential), ships it over SSH, runs `autoconfig.sh` to stand up code-server behind whatever already fronts the VM (auto-detecting the front door, the docker network, and a free port), then replicates your entire Claude Code environment inside the container. No ports to negotiate, nothing to wire by hand. Finish by adding the one Cloudflare DNS record it prints.

## Why

Long agent runs need a machine that stays on. Your laptop does not, and you should not have to babysit it. A small always-on VM survives every lid close, reboot, and commute. On OCI's Always-Free tier it costs nothing.

## Architecture

One front door owns :80 and :443. `autoconfig.sh` detects which of two situations it is in and adapts.

**integrate (primary, verified live).** The VM already runs Caddy inside Docker as the single front door for :80 and :443, serving other domains (sso.dmj.one, workday.dmj.one, testudaan.dmj.one). `autoconfig.sh` builds a small code-server image, runs it as its OWN container joined to that Caddy's docker network, and Caddy reaches it BY CONTAINER NAME. It publishes no host port, so the container is not reachable from the internet directly, and it never touches the host firewall.

```
Browser --HTTPS--> Cloudflare (Full mode: real TLS, DDoS, WAF, origin IP hidden)
                       |
                       v
                  OCI VM  :443
                  Caddy (Docker, the existing front door)
                    |-- sso.dmj.one        --> its container
                    |-- workday.dmj.one    --> its container
                    |-- testudaan.dmj.one  --> its container
                    '-- vscode.dmj.one     --> vscode-web:8080   (one appended site block)
                                                    |
                                                    v   shared docker network, no published host port
                                   vscode-web container: code-server
                                     |-- Claude Code CLI (10+ parallel agents)
                                     |-- Node 20 LTS + pnpm
                                     '-- NVIDIA_API_KEY in the shell
                                   volume vscode-web-home -> /home/coder  (persists restarts)
```

**standalone (greenfield, provided but not live-tested).** No front door on the box (a blank VM). `autoconfig.sh` runs code-server host-native under systemd on 127.0.0.1:8080 and installs Caddy natively to serve the domain. This path exists for convenience on a fresh VM. It has not been exercised on the author's box, so treat it as untested.

TLS: Cloudflare proxies the domain in Full mode. Caddy answers with `tls internal`, a self-signed origin cert. No public ACME, no cert to renew on the box.

## Why a container here, and not host-native

This is the interesting engineering point, so here it is straight. The first instinct is to run code-server directly on the host and point Caddy at `127.0.0.1:8080`. On a hardened box that returns 502. Hardened hosts commonly REJECT docker-to-host traffic except for a small whitelist, seen in the wild as an `INPUT ... -j REJECT --reject-with icmp-host-prohibited` rule, so the Caddy container cannot reach a host-native upstream. A container on the same docker bridge is the only non-invasive path, and it mirrors exactly how the box already proxies its other apps.

Docker was avoided elsewhere in this project to save RAM on small VMs. That tradeoff does not apply here: on a 24 GB or 32 GB box one code-server container (about 200 MB) is irrelevant, and a container is the correct tool for a hookup that must not disrupt anything already running.

## Non-disruption guarantees

The integrate path is built to add one site to a live front door without risking the others. In order, `autoconfig.sh`:

1. Backs up the Caddyfile before editing it.
2. Records the current HTTP status of every existing site as a baseline.
3. Appends exactly ONE site block for `vscode.dmj.one`.
4. Runs `caddy validate`. On failure it restores the backup and stops, no reload happens.
5. Reloads Caddy gracefully from a COPY of the config pushed into the container. A single-file docker bind mount follows the inode, so editing the host file can leave the running Caddy reading stale content. Validating and reloading from an in-container copy sidesteps that.
6. Re-checks every baseline site. If any previously-healthy site regressed, it rolls the Caddyfile back and reloads, then stops.

Verified across deploys: sso.dmj.one, workday.dmj.one, and testudaan.dmj.one were unchanged.

## Persistence

A named docker volume, `vscode-web-home`, holds `/home/coder`: your workspace, installed extensions, editor config, and the `claude` login. Restart or rebuild the container and all of it is still there.

## What lands on the server

`deploy/replicate-claude-env.sh` makes the server's Claude Code identical to your laptop, so you can close the lid and keep working from the browser:

- Your `CLAUDE.md`, `RTK.md`, `reference/`, `skills/`, and `settings.json`.
- Your credential, so `claude` is already logged in (real inference, your plan).
- Every plugin you run: the `dmj` marketplace (31 skills) cloned from GitHub, `caveman`, and the official plugins.
- The `anthropic.claude-code` VS Code extension, installed into code-server.

Personal config and the credential travel over SSH only. They never enter this repo: `.env` is gitignored, and the bundle is a runtime transfer that `deploy.sh` deletes from the VM when it is done.

## Cost

| Shape | vCPU | RAM | Arch | Always-Free | Monthly cost |
|---|---|---|---|---|---|
| Ampere A1.Flex (recommended) | up to 4 OCPU | 24 GB | arm64 | Yes | $0 |
| E5.Flex (this author's box) | 6 OCPU | 32 GB | x86_64 | No | paid, OCI on-demand pricing |

The free A1 is the zero-cost target and runs everything here. The E5 shape is not always-free; it bills per OCI on-demand pricing whenever it runs. The code-server base image is multi-arch and NodeSource ships arm64, so the inline build works on A1 (arm64) and E5 (x86_64) with no changes.

## Deploy in 2 steps

Prerequisite: an OCI VM you can SSH into, already fronted by a Caddy-in-Docker instance on :443 (the integrate case). To start from a blank VM, create an Always-Free Ampere A1.Flex (up to 4 OCPU / 24 GB) in the OCI Console, allow ingress on 80 and 443 in its security list, and note the public IP.

### 1. Copy the script and a filled `.env` to the VM
```bash
scp deploy/autoconfig.sh .env  user@vm:~
```
Fill `.env` from `.env.example`. Leave `CODE_SERVER_PASSWORD` blank to have autoconfig generate one, print it once, and save it back to `~/.env`.

### 2. Run autoconfig
```bash
sudo bash autoconfig.sh
```
It auto-detects the front door. If a Caddy container owns :443 it builds the code-server image, starts the `vscode-web` container on that Caddy's network, and integrates one site block (validate, graceful reload, auto-rollback if any existing site regresses). If nothing fronts :443 it falls back to standalone. Idempotent: rerun to rotate the password or pick up a changed `.env`.

### One manual step: the Cloudflare DNS record
`autoconfig.sh` cannot edit Cloudflare DNS, so it prints the exact record for you to add:
```
Type          A
Name          vscode
Value         <VM public IP>
Proxy         ON (orange cloud)
SSL/TLS mode  Full
```
Give it about a minute, then open https://vscode.dmj.one and log in with `CODE_SERVER_PASSWORD`.

## Running 10+ parallel Claude Code agents

Open a terminal inside code-server (Ctrl+`) and fan out:
```bash
claude                      # first run: authenticate once (persisted in the volume)
# then, across terminals or splits, fire agents in parallel:
claude --print "implement feature A" &
claude --print "implement feature B" &
claude --print "implement feature C" &
wait
```
24 GB (free A1) or 32 GB (the author's box) runs 10+ concurrent agents comfortably. Agents are network-bound: they spend most of their time waiting on API calls, not CPU, so a modest VM keeps up. If you set `CLAUDE_CODE_OAUTH_TOKEN` in `.env`, the CLI is pre-authenticated and you can skip the first `claude login`.

## NVIDIA build.nvidia.com models

`autoconfig.sh` passes `NVIDIA_API_KEY` into the container environment. Call any model from a terminal or a script:
```bash
curl -s https://integrate.api.nvidia.com/v1/chat/completions \
  -H "Authorization: Bearer $NVIDIA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-ai/deepseek-r1","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```
Swap the model id for GLM, Nemotron, Kimi K2, DeepSeek, or anything else in the build.nvidia.com catalog.

## Files

```
deploy.sh                 # one command: bundle ~/.claude, deploy, replicate. Run on your laptop.
deploy/
  autoconfig.sh           # stands up code-server. Detects the front door and
                          # integrates one Caddy site block (build image, run
                          # container on the front-door network, validate,
                          # graceful reload, auto-rollback), or falls back to
                          # standalone on a free host port. Idempotent.
  replicate-claude-env.sh # runs inside the container: config, plugins, key,
                          # and the VS Code extension. Idempotent.
.env.example              # all config; copy to .env (gitignored)
.gitattributes            # keep *.sh LF so scripts run on Linux
idea.md                   # the original problem statement
README.md
CHANGELOG.md
```

The container image (code-server + Node 20 + Claude Code CLI + pnpm) is built inline by `autoconfig.sh`. There is no separate Dockerfile or compose file in the repo.

## Security

- Password auth on code-server. It verifies the login; the password lives only in `.env`, written mode 600.
- Not exposed to the internet. In integrate mode the container publishes no host port, so only Caddy on the shared docker network can reach it. Cloudflare in Full mode hides the origin IP and provides real TLS, DDoS absorption, and WAF at the edge.
- Caddy sets HSTS, X-Content-Type-Options, X-Frame-Options, and Referrer-Policy on every response, and strips the Server header.
- Secrets live only in `.env`, mode 600, never in source.
- The host firewall is never modified. `autoconfig.sh` does not touch UFW, iptables, or fail2ban. Manage those at the OS or OCI security-list layer so a redeploy cannot disrupt the box.

## License

MIT
