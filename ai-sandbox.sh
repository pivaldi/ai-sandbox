GEMINI_API_KEY=XXXXXXXXXXXXXXXXXXXXXXXXXXXX
function ai-sandbox {
    local LATEST_VERSION
    LATEST_VERSION=$(curl -s https://registry.npmjs.org/@google/gemini-cli/latest | jq -r '.version')

    # Fallback just in case we are offline or the curl fails
    if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" == "null" ]; then
        echo "Failed to fetch latest Gemini CLI version. Falling back to 'latest'."
        LATEST_VERSION="latest"
    fi

    local IMAGE_NAME="ai-sandbox:$LATEST_VERSION"

    # Check if we already built this version locally
    if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        echo "New Gemini CLI version ($LATEST_VERSION) detected!"
        echo "Building updated sandbox image…"

        docker build --build-arg GEMINI_VERSION="$LATEST_VERSION" -t "$IMAGE_NAME" "$HOME/.ai-sandbox"
    fi

    local tty_args=""
    if [ -t 0 ]; then
        tty_args="-t"
    fi

    [ -d "$HOME/.claude" ] || mkdir -p "$HOME/.claude"
    [ -e "$HOME/.claude.json" ] || touch "$HOME/.claude.json"

    docker run -i ${tty_args} --rm \
        -v "$(pwd):/workspace" \
        -v "$HOME/.gemini:/home/gemini/.gemini" \
        -v "$HOME/.claude:/home/gemini/.claude" \
        -v "$HOME/.claude.json:/home/gemini/.claude.json" \
        -v "gemini-mise-config:/home/gemini/.config/mise" \
        -v "gemini-mise-cache:/home/gemini/.local/share/mise" \
        -e COLORTERM=truecolor \
        -e GEMINI_API_KEY="$GEMINI_API_KEY" \
        -e DEFAULT_UID="$(id -u)" \
        -e DEFAULT_GID="$(id -g)" \
        -e DEFAULT_USERNAME=gemini \
        "$IMAGE_NAME" "$@"
}
