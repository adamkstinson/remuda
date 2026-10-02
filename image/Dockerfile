# remuda-pi — Pi only. Tag: remuda-pi:latest (not the gem version).
FROM node:22-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ripgrep ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Pin Pi with the harness. Gem version ↔ image tag ↔ this package version.
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@0.85.1

# Remuda's Pi profile: the MCP client, loaded by the pi on PATH.
RUN npm install -g --ignore-scripts pi-mcp-adapter@4.0.0
COPY pi-profile/pi /opt/remuda/bin/pi
ENV PATH=/opt/remuda/bin:$PATH

WORKDIR /agent
USER node
ENTRYPOINT ["pi"]
