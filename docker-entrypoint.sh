#!/bin/bash
set -eu

TARGET_UID=${DEFAULT_UID:-1000}
TARGET_GID=${DEFAULT_GID:-1000}
USER=${DEFAULT_USERNAME:-gemini}
HOME=/home/$USER

# 1. Guarantee the container runs as our specific user and home directory
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

# 2. Inject Mise activation
echo 'eval "$(/usr/local/bin/mise activate bash)"' >>"$HOME/.bashrc"

# 3. Ensure config directories exist so mounts don't fail
mkdir -p "$HOME/.local/share/mise"
mkdir -p "$HOME/.gemini"
mkdir -p "$HOME/.claude"
touch "$HOME/.claude.json"

# Fix permissions
chown -R "$TARGET_UID:$TARGET_GID" "$HOME"

# 4. Execute the command
exec gosu "$USER" "$@"
