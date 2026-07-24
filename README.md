# vscode-web — VS Code in the browser on a GCloud VM

Run VS Code in your browser on an always-on GCloud VM. Code from your phone, tablet, or any browser. Switch off your laptop; the VM keeps coding. Preconfigured for **10+ parallel Claude Code agents** and **NVIDIA build.nvidia.com models** (GLM 5.2, Nemotron, Kimi K2, DeepSeek, etc.).

## Why

Your laptop is slow and you have to keep it on for long agent runs. A VM is always online, costs less than your electricity bill, and survives you closing the lid.

## Architecture

```
Browser ──HTTPS──> Cloudflare (TLS, DDoS, WAF) ──> GCloud VM (Nginx:443) ──> code-server (127.0.0.1:8080)
                                                          │
                                                          ├─ Claude Code CLI (10+ agents)
                                                          ├─ Node 20 LTS
                                                          └─ .env (NVIDIA_API_KEY, password)
```

- **code-server** (VS Code in the browser) behind Nginx with password auth
- **Argon2id** password hashing, **UFW** (22/80/443 only), **fail2ban** SSH guard
- **Cloudflare** in front: real TLS cert, DDoS, WAF (you add the DNS record manually)
- **Claude Code CLI** preinstalled for parallel agent workflows
- **NVIDIA build.nvidia.com** API key wired into the code-server environment

## Cost

| VM | RAM | 24/7 | Stopped when idle |
|---|---|---|---|
| e2-standard-2 (default) | 8 GB | ~$25/mo | ~$7/mo |
| e2-standard-4 | 16 GB | ~$50/mo | ~$14/mo |

**Stop the VM when you're not coding** to cut cost ~75% (you only pay for the disk while stopped):
```bash
gcloud compute instances stop code-server --zone=us-central1-a
gcloud compute instances start code-server --zone=us-central1-a
```
Note: the external IP may change on stop/start. Reserve a static IP if you want it stable (see `deploy/create-vm.sh` output).

## Deploy in 4 steps

### 1. Provision the VM
```bash
./deploy/create-vm.sh
```
Creates an e2-standard-2 VM in us-central1-a, opens firewall 80/443, prints the external IP.

### 2. Create `.env` and copy it to the VM
```bash
cp .env.example .env
# edit .env: set CODE_SERVER_PASSWORD (or leave blank to auto-generate), NVIDIA_API_KEY, etc.

VM=code-server
ZONE=us-central1-a
gcloud compute scp deploy/autoconfig.sh .env ${VM}:~/ --zone=${ZONE}
```

### 3. SSH in and bootstrap
```bash
gcloud compute ssh ${VM} --zone=${ZONE}
sudo bash ~/autoconfig.sh
```
Idempotent. Installs code-server, Node 20, Claude Code, Nginx, UFW, fail2ban. Binds code-server to 127.0.0.1:8080, Nginx fronts it on 443 with a self-signed cert (Cloudflare provides the real cert at the edge).

### 4. Add the Cloudflare DNS record (you, manually)
```
Type: A
Name: code
Target: <EXTERNAL_IP from step 1>
Proxy status: Proxied (orange cloud)
```
Wait ~60s, then open **https://code.dmj.one**. Log in with your password.

## Running 10+ parallel Claude Code agents

Once logged into code-server, open a terminal (Ctrl+\`) and:
```bash
claude                    # first run: `claude login` to auth
# then in multiple terminals / splits, fire agents in parallel:
claude --print "implement feature A" &
claude --print "implement feature B" &
claude --print "implement feature C" &
wait
```
e2-standard-2 (8 GB) handles ~10 concurrent agents. For 15+, bump to e2-standard-4.

## NVIDIA build.nvidia.com models

Your `NVIDIA_API_KEY` is exported in the code-server shell. Use it from any script:
```bash
curl -s https://integrate.api.nvidia.com/v1/chat/completions \
  -H "Authorization: Bearer $NVIDIA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-ai/deepseek-r1","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```
Or wire it into a code-server extension / MCP server for in-editor model switching.

## Files

```
deploy/
  create-vm.sh        # gcloud VM provisioning (idempotent)
  autoconfig.sh       # VM bootstrap: blank Ubuntu -> code-server on 443 (idempotent)
  Dockerfile          # code-server + Node + Claude Code (for local parity)
  docker-compose.yml  # local dev
.env.example          # all config; copy to .env
```

## Security

- Password auth on code-server (Argon2id hashed audit copy)
- UFW: only 22/80/443 open
- fail2ban: SSH brute-force protection (5 fails -> 1h ban)
- Cloudflare proxy: real TLS, DDoS, WAF, hides origin IP
- Secrets in `.env` (mode 600), never in source
- code-server bound to 127.0.0.1 only; never directly exposed

## Teardown

```bash
gcloud compute instances delete code-server --zone=us-central1-a
gcloud compute firewall-rules delete allow-http-https
```

## License

MIT
