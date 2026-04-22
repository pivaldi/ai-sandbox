GEMINI_API_KEY=XXXXXXXXXXXXXXXXXXXXXXXXXXXX
function ai-sandbox {
    local GEMINI_VERSION CLAUDE_VERSION IMAGE_NAME

    GEMINI_VERSION=$(curl -s https://registry.npmjs.org/@google/gemini-cli/latest | jq -r '.version')
    CLAUDE_VERSION=$(curl -s https://registry.npmjs.org/@anthropic-ai/claude-code/latest | jq -r '.version')

    if [ -z "$GEMINI_VERSION" ] || [ "$GEMINI_VERSION" == "null" ]; then
        echo "Failed to fetch latest Gemini CLI version. Falling back to 'latest'."
        GEMINI_VERSION="latest"
    fi

    if [ -z "$CLAUDE_VERSION" ] || [ "$CLAUDE_VERSION" == "null" ]; then
        echo "Failed to fetch latest Claude Code version. Falling back to 'latest'."
        CLAUDE_VERSION="latest"
    fi

    IMAGE_NAME="ai-sandbox:gemini-${GEMINI_VERSION}-claude-${CLAUDE_VERSION}"

    if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        echo "New version detected (Gemini: $GEMINI_VERSION, Claude: $CLAUDE_VERSION)!"
        echo "Building updated sandbox image…"

        docker build \
            --build-arg GEMINI_VERSION="$GEMINI_VERSION" \
            --build-arg CLAUDE_VERSION="$CLAUDE_VERSION" \
            -t "$IMAGE_NAME" "$HOME/.ai-sandbox"
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
