# Use an ARG to inject the version dynamically
ARG GEMINI_VERSION=latest
ARG CLAUDE_VERSION=latest

FROM us-docker.pkg.dev/gemini-code-dev/gemini-cli/sandbox:${GEMINI_VERSION}

USER root

RUN apt-get update && apt-get install -y \
    curl tree make git gosu build-essential \
    unzip jq ripgrep libsecret-1-0 tmux openssh-client \
    docker.io \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22.x (which includes npm) via NodeSource.
#
# The base image ships its own Node under /usr/local/bin, which precedes
# /usr/bin in PATH. Installing NodeSource alone is therefore not enough:
# both the `npm install -g` below and every runtime `#!/usr/bin/env node`
# shebang keep resolving to the older Node, so packages install against an
# unsupported engine (gitnexus requires ^22.18.0 || >=24.11.0). Point the
# /usr/local/bin names at the NodeSource binaries, then assert the version
# so a future base-image change fails the build instead of regressing here.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && for b in node npm npx; do \
         if [ -e "/usr/bin/$b" ]; then ln -sf "/usr/bin/$b" "/usr/local/bin/$b"; fi; \
       done \
    && node -e 'if (+process.versions.node.split(".")[0] < 22) { console.error("expected Node >= 22, got " + process.version); process.exit(1) }' \
    && echo "Node: $(node -v), npm: $(npm -v)"

RUN curl -Ls https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION} gitnexus@latest
RUN curl -fsSL https://roborev.io/install.sh | bash

COPY docker-entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace

# The container must start as root to create the user, then the entrypoint drops to the gemini user
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
