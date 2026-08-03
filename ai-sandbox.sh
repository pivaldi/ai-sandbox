function ai-sandbox {
    local subcommand="${1:-}"
    AIO_PORT=${AIO_PORT:-8181}

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
    # Create an isolated network if it doesn't exist
    # docker network inspect ai-net >/dev/null 2>&1 || docker network create ai-net

    # if ! docker ps --format '{{.Names}}' | grep -Eq "^aio-sandbox\$"; then
    #     echo "Starting background aio-sandbox (agent-infra/sandbox)..."
    #     # Clean up any dead containers with the same name
    #     docker rm aio-sandbox >/dev/null 2>&1 || true
    #     docker run -d \
        #         --name "aio-sandbox" \
        #         # --network ai-net \
        #         -v "$(pwd):/workspace" \
        #         -p "${AIO_PORT}:8080" \
        #         ghcr.io/agent-infra/sandbox:latest > /dev/null
    # fi

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
    # shellcheck disable=SC2206 # ${tty_args} must disappearing completely if it is empty
    local docker_args=(
        docker run -i ${tty_args} --rm
        # --network ai-net
        -v "$(pwd):/workspace"
        -v "$HOME/.gemini:/home/gemini/.gemini"
        -v "$HOME/.claude:/home/gemini/.claude"
        -v "$HOME/.claude.json:/home/gemini/.claude.json"
        -v "gemini-mise-config:/home/gemini/.config/mise"
        -v "gemini-mise-cache:/home/gemini/.local/share/mise"
        -e COLORTERM=truecolor
        -e MISE_TRUSTED_CONFIG_PATHS="/workspace"
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
        echo "Starting Claude Code (Pro Subscription)..."
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

function ai-bwrap {
    local subcommand="${1:-}"

    # Resolve the directory this script lives in (follows the ~/.ai-sandbox
    # symlink) so we can bind repo-local dotfiles like .bashrc into the jail,
    # independent of the current project directory.
    local AI_SANDBOX_DIR
    AI_SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [ -f "$(pwd)/.env" ]; then
        set -al; source "$(pwd)/.env"; set +al
    fi

    MISE_TRUSTED_CONFIG_PATHS="$(pwd)"
    export MISE_TRUSTED_CONFIG_PATHS

    # Ensure the mise directories exist on the host so the bind doesn't crash
    for path in "$HOME/.local/share/mise" "$HOME/.local/state/mise" "$HOME/.config/mise"; do
        [ -e "$path" ] || mkdir -p "$path"
    done

    # ---------------------------------------------------------
    # The Ironclad Whitelist bwrap Command
    # ---------------------------------------------------------
    # We define the sandbox as an array so we can apply it to ANY agent.
    # Notice we do NOT bind /etc/ as a whole. We only bind the absolute
    # bare minimum files required for the internet to work.
    local sandbox_cmd=(
        bwrap
        --unshare-all
        --share-net
        --ro-bind /usr /usr
        --tmpfs /usr/local/blockchain
        --ro-bind /lib /lib
        --ro-bind /lib64 /lib64
        --ro-bind /bin /bin
        --ro-bind-try /sbin /sbin
        --ro-bind-try /opt/emacs/ /opt/emacs/

        --ro-bind /etc/resolv.conf /etc/resolv.conf
        --ro-bind /etc/ssl/certs /etc/ssl/certs
        --ro-bind-try /etc/alternatives /etc/alternatives
        --ro-bind-try /etc/passwd /etc/passwd
        --ro-bind-try /etc/group /etc/group
        --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf
        --ro-bind-try /etc/profile /etc/profile
        --ro-bind-try /etc/bash.bashrc /etc/bash.bashrc
        --ro-bind-try /etc/ld.so.cache /etc/ld.so.cache

        --bind-try "$HOME/.npm" "$HOME/.npm"
        --bind-try "$HOME/.npm-global" "$HOME/.npm-global"
        --bind-try "$NVM_DIR" "$NVM_DIR"

        --dev /dev
        --proc /proc
        --tmpfs /tmp
        --bind "$(pwd)" "$(pwd)"
        --ro-bind-try "$HOME/.local/bin" "$HOME/.local/bin"
        --bind "$HOME/.claude" "$HOME/.claude"
        --bind "$HOME/.claude.json" "$HOME/.claude.json"
        --bind "$HOME/.gemini" "$HOME/.gemini"
        --ro-bind-try "$HOME/.local/share/mise" "$HOME/.local/share/mise"
        --ro-bind-try "$HOME/.local/state/mise" "$HOME/.local/state/mise"
        --ro-bind-try "$HOME/.config/mise" "$HOME/.config/mise"
        --ro-bind-try "$HOME/.cargo" "$HOME/.cargo"
        --bind-try "$HOME/bin/go" "$HOME/bin/go"
        --bind-try "$HOME/code/go" "$HOME/code/go"
        --bind-try "$HOME/.cache/go-build" "$HOME/.cache/go-build"
        --ro-bind-try "${HOME}/.nix-profile/bin" "${HOME}/.nix-profile/bin"
        --ro-bind-try "$AI_SANDBOX_DIR/.bashrc" "$HOME/.bashrc"
        --ro-bind-try "$HOME/.profile" "$HOME/.profile"
        --ro-bind-try "$HOME/.bash_profile" "$HOME/.bash_profile"
        --ro-bind-try "$HOME/.config/composer/" "$HOME/.config/composer/"
        --bind-try "$HOME/.config/roborev" "$HOME/.config/roborev"
        --bind-try "$HOME/.roborev" "$HOME/.roborev"
        --ro-bind-try /nix/ /nix/
        --ro-bind-try "$HOME/node_modules" "$HOME/node_modules"
        --ro-bind-try "$HOME/.lbdb/" "$HOME/.lbdb/"
        --bind-try "$HOME/.cache/gitnexus" "$HOME/.cache/gitnexus"
        --chdir "$(pwd)"
    )

    # ---------------------------------------------------------
    # Execution Routing
    # ---------------------------------------------------------
    if [ "$subcommand" == "pro" ]; then
        echo "Starting Claude (Custom Whitelist Jail - Pro Subscription)..."
        env -u ANTHROPIC_API_KEY "${sandbox_cmd[@]}" npx -y @anthropic-ai/claude-code

    elif [ "$subcommand" == "api" ]; then
        echo "Starting Claude (Custom Whitelist Jail - Personal API Key)..."
        "${sandbox_cmd[@]}" npx -y @anthropic-ai/claude-code

    elif [ "$subcommand" == "gemini" ]; then
        if [ -z "${GEMINI_API_KEY:-}" ]; then
            echo "Error: GEMINI_API_KEY is not set."
            return 1
        fi
        echo "Starting Gemini CLI (Custom Whitelist Jail)..."
        "${sandbox_cmd[@]}" npx -y @google/gemini-cli

    elif [ "$subcommand" == "login" ]; then
        npx -y @anthropic-ai/claude-code login

    elif [ "$subcommand" == "roborev" ]; then
        echo "Starting Roborev (Orchestrator Jail)..."

        # 3. Execute Roborev inside the jail
        # We inject our shim directory at the very front of the PATH
        "${sandbox_cmd[@]}" mise exec -- roborev "${@:2}"

    else
        echo "Usage: ai-brawp [pro|api|gemini|login]"
    fi
}
