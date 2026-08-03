#!/bin/bash
set -eu

TARGET_UID=${DEFAULT_UID:-1000}
TARGET_GID=${DEFAULT_GID:-1000}
USER=${DEFAULT_USERNAME:-gemini}
HOME=/home/$USER
AIO_PORT=${AIO_PORT:-8181}

# Guarantee the container runs as our specific user and home directory
if EXISTING_USER=$(getent passwd "$TARGET_UID" | cut -d: -f1); then
    if [ "$EXISTING_USER" != "$USER" ]; then
        # Rename the existing user (e.g., 'node') to 'gemini'
        usermod -l "$USER" "$EXISTING_USER" >/dev/null 2>&1 || true
        # Change their home directory to /home/gemini and move existing files
        usermod -d "$HOME" -m "$USER" >/dev/null 2>&1 || true
    fi
else
    # Create the new group and user from scratch
    getent group "$TARGET_GID" >/dev/null 2>&1 || groupadd -g "$TARGET_GID" "$USER"
    useradd -m -u "$TARGET_UID" -g "$TARGET_GID" -d "$HOME" -s /bin/bash "$USER"
fi

# Ensure the gemini user can access the mounted docker socket for MCP commands
if [ -S /var/run/docker.sock ]; then
    DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
    # Create a group for the host's docker GID if it doesn't exist in the container
    getent group "$DOCKER_GID" >/dev/null 2>&1 || groupadd -g "$DOCKER_GID" docker_host
    # Add gemini to that group
    usermod -aG "$DOCKER_GID" "$USER"
fi

# Inject Mise activation (>> is naturally silent)
# shellcheck disable=SC2016
echo 'eval "$(/usr/local/bin/mise activate bash)"' >>"$HOME/.bashrc"

# Ensure config directories exist so mounts don't fail
mkdir -p "$HOME/.local/share/mise"
mkdir -p "$HOME/.gemini"
mkdir -p "$HOME/.claude"
touch "$HOME/.claude.json"

# Fix permissions
chown -R "$TARGET_UID:$TARGET_GID" "$HOME"

# Bootstrap everything-claude-code
ECC_REPO="$HOME/.claude/everything-claude-code"

if ! grep -q "everything-claude-code" "$HOME/.claude.json" 2>/dev/null; then
    gosu "$USER" claude plugin marketplace add affaan-m/everything-claude-code >/dev/null || true
    gosu "$USER" claude plugin install everything-claude-code@everything-claude-code >/dev/null || true

    # Safe cloning: Only clone if the directory doesn't already exist
    if [ ! -d "$ECC_REPO" ]; then
        gosu "$USER" git clone https://github.com/affaan-m/everything-claude-code.git "$ECC_REPO" >/dev/null
    fi

    gosu "$USER" bash -c "cd $ECC_REPO && chmod +x install.sh && ./install.sh --target gemini --profile full > /dev/null" || true
fi

# GitNexus MCP Registration
if ! grep -q "gitnexus" "$HOME/.claude.json" 2>/dev/null; then
    gosu "$USER" claude mcp add gitnexus -- gitnexus mcp >/dev/null || true
fi

# AIO Sandbox MCP Registration (Network-Isolated API Bridge)
if ! grep -q "aio-sandbox" "$HOME/.claude.json" 2>/dev/null; then
    # Use mcp-proxy to convert Claude's stdio to SSE and beam it across the virtual ai-net
    gosu "$USER" claude mcp add aio-sandbox -- npx -y mcp-proxy "http://aio-sandbox:${AIO_PORT}/sse" >/dev/null || true
fi

# Auto-pin the latest fully-installed version of every mise tool as the global default.
MISE_INSTALLS="$HOME/.local/share/mise/installs"
if [ -d "$MISE_INSTALLS" ]; then
    for TOOL_DIR in "$MISE_INSTALLS"/*/; do
        # Ensure it's actually a directory (handles edge cases where the folder is empty)
        [ -d "$TOOL_DIR" ] || continue
        TOOL=$(basename "$TOOL_DIR")

        # find directories starting with a number, sort them, and read line-by-line
        while IFS= read -r VER; do
            [ -z "$VER" ] && continue
            BIN_DIR="${TOOL_DIR}${VER}/bin"

            if [ -d "$BIN_DIR" ] && [ -n "$(ls -A "$BIN_DIR" 2>/dev/null)" ]; then
                gosu "$USER" /usr/local/bin/mise use -g "${TOOL}@${VER}" >/dev/null 2>&1 || true
                break
            fi
        done < <(find "$TOOL_DIR" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -printf '%f\n' 2>/dev/null | sort -rV)
    done
fi

# Silently trust the mounted workspace so mise doesn't complain and leak text
gosu "$USER" /usr/local/bin/mise trust /workspace >/dev/null 2>&1 || true

# Execute via `mise exec` so all globally configured tools are in PATH.
exec gosu "$USER" /usr/local/bin/mise exec -- "$@"
