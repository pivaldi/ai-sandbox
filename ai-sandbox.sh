function ai-sandbox {
    local subcommand="${1:-}"

    # ---------------------------------------------------------
    # 1. Cleanup Command
    # ---------------------------------------------------------
    if [ "$subcommand" == "stop" ]; then
        echo "Stopping background aio-sandbox..."
        docker stop aio-sandbox >/dev/null 2>&1 || true
        docker rm aio-sandbox >/dev/null 2>&1 || true
        echo "Sandbox stopped."
        return 0
    fi

    # ---------------------------------------------------------
    # 2. Pre-flight Checks & Versioning
    # ---------------------------------------------------------
    if [ -z "${GEMINI_API_KEY:-}" ]; then
        echo "Error: GEMINI_API_KEY is not set. Export it in your shell profile before sourcing this script."
        return 1
    fi

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
            -t "$IMAGE_NAME" "$HOME/.ai-sandbox" \
            -t "ai-sandbox:latest"
    fi

    # ---------------------------------------------------------
    # 3. Ensure AIO Sandbox is Running
    # ---------------------------------------------------------
    if ! docker ps --format '{{.Names}}' | grep -Eq "^aio-sandbox\$"; then
        echo "Starting background aio-sandbox (agent-infra/sandbox)..."
        # Clean up any dead containers with the same name
        docker rm aio-sandbox >/dev/null 2>&1 || true 
        docker run -d \
            --name "aio-sandbox" \
            -v "$(pwd):/workspace" \
            -p 8181:8080 \
            ghcr.io/agent-infra/sandbox:latest > /dev/null
    fi

    # ---------------------------------------------------------
    # 4. Prepare Client Base Arguments
    # ---------------------------------------------------------
    local tty_args=""
    if [ -t 0 ]; then
        tty_args="-t"
    fi

    [ -d "$HOME/.claude" ] || mkdir -p "$HOME/.claude"
    [ -e "$HOME/.claude.json" ] || touch "$HOME/.claude.json"

    # Base docker array (Keeps syntax clean)
    local docker_args=(
        # shellcheck disable=SC2206 # unquoted variable must disappearing completely if it is empty
        docker run -i ${tty_args} --rm
        -v "$(pwd):/workspace"
        -v "$HOME/.gemini:/home/gemini/.gemini"
        -v "$HOME/.claude:/home/gemini/.claude"
        -v "$HOME/.claude.json:/home/gemini/.claude.json"
        -v "gemini-mise-config:/home/gemini/.config/mise"
        -v "gemini-mise-cache:/home/gemini/.local/share/mise"
        -v "/var/run/docker.sock:/var/run/docker.sock" # Added for MCP communication
        -e COLORTERM=truecolor
        -e GEMINI_API_KEY="$GEMINI_API_KEY"
        -e DEFAULT_UID="$(id -u)"
        -e DEFAULT_GID="$(id -g)"
        -e DEFAULT_USERNAME=gemini
    )

    # ---------------------------------------------------------
    # 5. Routing Execution (The Billing Swap)
    # ---------------------------------------------------------
    if [ "$subcommand" == "login" ]; then
        "${docker_args[@]}" "$IMAGE_NAME" claude login

    elif [ "$subcommand" == "pro" ]; then
        echo "Starting Claude Code (Employer Pro Subscription)..."
        # Purposely omit ANTHROPIC_API_KEY
        "${docker_args[@]}" "$IMAGE_NAME" claude

    elif [ "$subcommand" == "api" ]; then
        if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
            echo "Error: ANTHROPIC_API_KEY is not set. Add it to a .env file or export it."
            return 1
        fi
        echo "Starting Claude Code (Personal API Key)..."
        # Explicitly pass the key into the container
        "${docker_args[@]}" -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" "$IMAGE_NAME" claude

    else
        # Fallback: Treat as standard arguments (e.g., ai-sandbox gemini "prompt", or ai-sandbox bash)
        "${docker_args[@]}" -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" "$IMAGE_NAME" "$@"
    fi
}
