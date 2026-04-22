# Use an ARG to inject the version dynamically
ARG GEMINI_VERSION=latest
ARG CLAUDE_VERSION=latest

FROM us-docker.pkg.dev/gemini-code-dev/gemini-cli/sandbox:${GEMINI_VERSION}

USER root

RUN apt-get update && apt-get install -y \
    curl tree make git gosu build-essential \
    unzip jq ripgrep libsecret-1-0 tmux \
    && rm -rf /var/lib/apt/lists/*

RUN curl -Ls https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION}

COPY docker-entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace

# The container must start as root to create the user, then the entrypoint drops to the gemini user
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
