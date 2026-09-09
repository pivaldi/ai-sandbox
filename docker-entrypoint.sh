#!/bin/bash
set -eu

TARGET_UID=${DEFAULT_UID:-1000}
TARGET_GID=${DEFAULT_GID:-1000}
USER=${DEFAULT_USERNAME:-gemini}
# The launcher passes the host's $HOME so the container agrees with ai-bwrap
# on absolute paths written into the shared ~/.claude (plugin installPath,
# marketplace installLocation, hook commands).
HOME=${DEFAULT_HOME:-/home/$USER}
AIO_PORT=${AIO_PORT:-8181}

# Guarantee the container runs as our specific user and home directory
mkdir -p "$HOME"

if EXISTING_USER=$(getent passwd "$TARGET_UID" | cut -d: -f1); then
    if [ "$EXISTING_USER" != "$USER" ]; then
        # Rename the existing user (e.g., 'node') to the host's username
        usermod -l "$USER" "$EXISTING_USER" >/dev/null 2>&1 || true
    fi
    # Point the account at the shared home. No -m: Docker pre-creates $HOME
    # for the bind mounts, and usermod refuses to move onto a directory that
    # already exists. Nothing needs moving anyway -- the dotfiles this image
    # cares about are either bind-mounted or written below.
    usermod -d "$HOME" "$USER" >/dev/null 2>&1 || true
else
    # Create the new group and user from scratch
    getent group "$TARGET_GID" >/dev/null 2>&1 || groupadd -g "$TARGET_GID" "$USER"
    useradd -u "$TARGET_UID" -g "$TARGET_GID" -d "$HOME" -s /bin/bash "$USER"
fi

# Fail loudly rather than silently landing on the wrong home: gosu reads the
# home out of /etc/passwd, so a missed usermod would send the CLIs to an
# unmounted directory and quietly desynchronise the shared plugin config.
ACTUAL_HOME=$(getent passwd "$USER" | cut -d: -f6)
if [ "$ACTUAL_HOME" != "$HOME" ]; then
    echo "entrypoint: could not set home for '$USER': passwd says '$ACTUAL_HOME', expected '$HOME'" >&2
    exit 1
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

# Shim roborev onto the host-shaped path the shared config expects.
# ~/.claude/settings.json points its Bash hooks at an absolute host path
# ($HOME/bin/go/roborev), so without this every tool call reports a
# Pre/PostToolUse hook failure. $HOME/bin is container-local -- it is not one
# of the bind mounts -- so this cannot touch the host. Created after the
# chown above, hence the explicit ownership fixes.
ROBOREV_BIN=$(command -v roborev 2>/dev/null || true)
if [ -n "$ROBOREV_BIN" ]; then
    mkdir -p "$HOME/bin/go"
    ln -sf "$ROBOREV_BIN" "$HOME/bin/go/roborev"
    chown "$TARGET_UID:$TARGET_GID" "$HOME/bin" "$HOME/bin/go"
    chown -h "$TARGET_UID:$TARGET_GID" "$HOME/bin/go/roborev"
fi

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

# Silently trust the mounted project so mise doesn't complain and leak text.
# The launcher mounts it at its real host path, so PROJECT_DIR carries that
# path in; /workspace remains the fallback for a bare `docker run`.
gosu "$USER" /usr/local/bin/mise trust "${PROJECT_DIR:-/workspace}" >/dev/null 2>&1 || true

# Register this project's existing index with the container's own registry.
# ~/.gitnexus is deliberately not shared with the host (see ai-sandbox.sh), so
# the container has to register for itself. This is a pointer write, not a
# re-analysis: the index lives in the repo's .gitnexus/, mounted with it.
GITNEXUS_BIN=$(command -v gitnexus 2>/dev/null || true)
if [ -z "$GITNEXUS_BIN" ] && [ -x /usr/local/share/npm-global/bin/gitnexus ]; then
    GITNEXUS_BIN=/usr/local/share/npm-global/bin/gitnexus
fi
if [ -n "$GITNEXUS_BIN" ] && [ -d "${PROJECT_DIR:-/workspace}/.gitnexus" ]; then
    gosu "$USER" "$GITNEXUS_BIN" index "${PROJECT_DIR:-/workspace}" >/dev/null 2>&1 || true
fi

# Execute via `mise exec` so all globally configured tools are in PATH.
exec gosu "$USER" /usr/local/bin/mise exec -- "$@"
