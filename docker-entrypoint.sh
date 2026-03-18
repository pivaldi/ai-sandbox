#!/bin/bash
set -eu

TARGET_UID=${DEFAULT_UID:-1000}
TARGET_GID=${DEFAULT_GID:-1000}
USER=${DEFAULT_USERNAME:-gemini}

# 1. Check if the UID already exists in the container
if EXISTING_USER=$(getent passwd "$TARGET_UID" | cut -d: -f1); then
    # Adopt the existing user and its home directory
    if [ -n "$EXISTING_USER" ]; then
        USER="$EXISTING_USER"
        HOME=$(getent passwd "$TARGET_UID" | cut -d: -f6)
    fi
else
    # Create the new group and user
    HOME=/home/$USER
    getent group "$TARGET_GID" >/dev/null 2>&1 || groupadd -g "$TARGET_GID" "$USER"
    useradd -m -u "$TARGET_UID" -g "$TARGET_GID" -d "$HOME" -s /bin/bash "$USER"
fi

# 2. Inject Mise activation into the bashrc
echo 'eval "$(/usr/local/bin/mise activate bash)"' >>"$HOME/.bashrc"

# 3. Pre-create folders and fix permissions
mkdir -p "$HOME/.local/share/mise"
mkdir -p "$HOME/.gemini"
chown -R "$TARGET_UID:$TARGET_GID" "$HOME"

# 4. Execute the command as the resolved user
exec gosu "$USER" "$@"
