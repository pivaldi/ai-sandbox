#!/bin/bash
set -eu

TARGET_UID=${DEFAULT_UID:-1000}
TARGET_GID=${DEFAULT_GID:-1000}
USER=${DEFAULT_USERNAME:-gemini}
HOME=/home/$USER

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

# Inject Mise activation (>> is naturally silent)
echo 'eval "$(/usr/local/bin/mise activate bash)"' >> "$HOME/.bashrc"

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
    echo "Bootstrapping everything-claude-code for the first time..." >&2

    # Send stdout to /dev/null before || true
    gosu "$USER" claude plugin marketplace add affaan-m/everything-claude-code > /dev/null || true
    gosu "$USER" claude plugin install everything-claude-code@everything-claude-code > /dev/null || true

    # Safe cloning: Only clone if the directory doesn't already exist
    if [ ! -d "$ECC_REPO" ]; then
        gosu "$USER" git clone https://github.com/affaan-m/everything-claude-code.git "$ECC_REPO" > /dev/null
    else
        echo "Repo directory already exists, skipping clone..." >&2
    fi

    gosu "$USER" bash -c "cd $ECC_REPO && chmod +x install.sh && ./install.sh --target gemini --profile full > /dev/null" || true
else
    echo "everything-claude-code is already installed. Skipping bootstrap." >&2
fi
# ---------------------------------------------

# Auto-pin the latest fully-installed version of every mise tool as the global default.
MISE_INSTALLS="$HOME/.local/share/mise/installs"
if [ -d "$MISE_INSTALLS" ]; then
    for TOOL_DIR in "$MISE_INSTALLS"/*/; do
        TOOL=$(basename "$TOOL_DIR")
        for VER in $(ls "$TOOL_DIR" 2>/dev/null | grep -E '^[0-9]' | sort -rV); do
            BIN_DIR="$TOOL_DIR$VER/bin"
            if [ -d "$BIN_DIR" ] && [ -n "$(ls -A "$BIN_DIR" 2>/dev/null)" ]; then
                gosu "$USER" /usr/local/bin/mise use -g "${TOOL}@${VER}" >/dev/null 2>&1 || true
                break
            fi
        done
    done
fi

# Install GitNexus globally so it doesn't download every time
if ! gosu "$USER" /usr/local/bin/mise exec -- command -v gitnexus >/dev/null 2>&1; then
    echo "Installing GitNexus globally..." >&2
    gosu "$USER" /usr/local/bin/mise exec -- npm install -g gitnexus >/dev/null 2>&1 || true

    # Tell mise to rebuild its shims so the 'gitnexus' command becomes available
    gosu "$USER" /usr/local/bin/mise reshim >/dev/null 2>&1 || true
fi

# Execute via `mise exec` so all globally configured tools are in PATH.
exec gosu "$USER" /usr/local/bin/mise exec -- "$@"
