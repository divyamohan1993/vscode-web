# Dockerfile for code-server with Node + Claude Code preinstalled.
# Multi-stage, non-root, read-only-friendly. Used by docker-compose.yml.
# NOTE: For this project we deploy code-server directly on the VM (autoconfig.sh)
# because Claude Code agents need full system access + persistent state across
# restarts. This Dockerfile is provided for local dev / parity testing.

FROM codercom/code-server:4.90.0 AS base
USER root

# System deps + build tools for agent workflows
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget git jq build-essential python3 python3-pip \
    ca-certificates gnupg2 argon2 sudo \
    && rm -rf /var/lib/apt/lists/*

# Node 20 LTS (code-server bundles an old node; agents need modern node)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI + global tools
RUN npm install -g @anthropic-ai/claude-code pnpm typescript tsx

# Non-root user 'coder' already exists in the base image (uid 1000)
USER coder
ENV HOME=/home/coder
WORKDIR /home/coder

# code-server config is injected via env / volume at runtime
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["code-server", "--bind-addr", "0.0.0.0:8080", "--auth", "password", "."]
