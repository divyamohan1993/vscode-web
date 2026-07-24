# CHANGELOG

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- `deploy/create-vm.sh`: idempotent GCloud VM provisioning (e2-standard-2, us-central1-a, firewall 80/443)
- `deploy/autoconfig.sh`: idempotent VM bootstrap (code-server + Node 20 + Claude Code + Nginx + UFW + fail2ban, Argon2id password, TLS, health check)
- `deploy/Dockerfile` + `docker-compose.yml`: local parity environment for code-server
- `.env.example`: all configuration (password, NVIDIA_API_KEY, Claude token, domain, VM sizing)
- `README.md`: end-to-end deploy guide, cost table, 10-agent workflow, NVIDIA model usage
- `.gitignore`: secrets and local artifacts excluded
