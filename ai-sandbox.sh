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

    # Pre-create every bind source, otherwise Docker creates the missing ones
    # as root-owned directories on the host.
    for path in "$HOME/.claude" "$HOME/.gemini" "$HOME/.gitnexus-docker" "$HOME/.lbdb"; do
        [ -d "$path" ] || mkdir -p "$path"
    done
    [ -e "$HOME/.claude.json" ] || touch "$HOME/.claude.json"

    # Base docker array (Keeps syntax clean)
    # shellcheck disable=SC2206 # ${tty_args} must disappearing completely if it is empty
    local docker_args=(
        docker run -i ${tty_args} --rm
        # --network ai-net
        # Mount the project at its real host path, not /workspace: gitnexus's
        # registry, Claude's project-scoped config and .gitnexus/meta.json all
        # key on the absolute project path, so a container-only path makes both
        # modes disagree the same way a container-only $HOME did.
        -v "$(pwd):$(pwd)"
        -w "$(pwd)"
        # Mount to the *host* $HOME, not /home/gemini: Claude Code records
        # absolute paths (plugin installPath, marketplace installLocation,
        # hook commands) inside the shared ~/.claude, so the container and
        # ai-bwrap must agree on what $HOME is or each corrupts the other.
        -v "$HOME/.gemini:$HOME/.gemini"
        -v "$HOME/.claude:$HOME/.claude"
        -v "$HOME/.claude.json:$HOME/.claude.json"
        # Deliberately NOT the host's ~/.gitnexus. Its registry.json is small
        # mutable coordination state with no locking, so a container MCP server
        # and a host/bwrap one sharing it overwrite each other's registrations.
        # The expensive artefact -- the index itself -- lives in the repo's own
        # .gitnexus/ and is already shared through the project mount above.
        -v "$HOME/.gitnexus-docker:$HOME/.gitnexus"
        # LadybugDB caches its FTS/vector extensions here, keyed by version and
        # platform. Without this the container starts with an empty cache and,
        # being --rm, throws away every download -- so GitNexus search silently
        # degrades to no full-text index on each run. Safe to share with the
        # host, unlike the registry above: it is an immutable content cache.
        -v "$HOME/.lbdb:$HOME/.lbdb"
        -v "gemini-mise-config:$HOME/.config/mise"
        -v "gemini-mise-cache:$HOME/.local/share/mise"
        -e COLORTERM=truecolor
        -e MISE_TRUSTED_CONFIG_PATHS="$(pwd)"
        -e PROJECT_DIR="$(pwd)"
        -e GEMINI_API_KEY="$GEMINI_API_KEY"
        -e DEFAULT_UID="$(id -u)"
        -e DEFAULT_GID="$(id -g)"
        -e DEFAULT_HOME="$HOME"
        -e DEFAULT_USERNAME="$(id -un)"
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

    # Refuse to launch from $HOME or any ancestor of it: --bind "$(pwd)" would
    # hand the jail the very tree the whitelist exists to hide, and bwrap then
    # dies mounting whitelist entries onto symlinks such as ~/.nix-profile/bin.
    # login is exempt because it runs outside the jail.
    if [ "$subcommand" != "login" ]; then
        case "$HOME/" in
            "${PWD%/}/"*)
                echo "ai-bwrap: refusing to run from $PWD: it contains your home directory, so the jail would expose it read-write. cd into a project directory first." >&2
                return 1
                ;;
        esac
    fi

    # Resolve the directory this script lives in (follows the ~/.ai-sandbox
    # symlink) so we can bind repo-local dotfiles like .bashrc into the jail,
    # independent of the current project directory.
    local AI_SANDBOX_DIR
    AI_SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [ -f "$(pwd)/.env" ]; then
        set -al
        source "$(pwd)/.env"
        set +al
    fi

    MISE_TRUSTED_CONFIG_PATHS="$(pwd)"
    export MISE_TRUSTED_CONFIG_PATHS

    # Ensure the mise directories exist on the host so the bind doesn't crash,
    # and ocr's state dir so its --bind-try below is never silently skipped.
    for path in "$HOME/.local/share/mise" "$HOME/.local/state/mise" "$HOME/.config/mise" "$HOME/.opencodereview"; do
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
        --ro-bind /etc/hosts /etc/hosts
        --ro-bind-try /opt/emacs/ /opt/emacs/
        --dev-bind /dev/net/tun /dev/net/tun # (if needed for VPNs/tunneling)

        --ro-bind /etc/resolv.conf /etc/resolv.conf
        --ro-bind /etc/ssl/certs /etc/ssl/certs
        --ro-bind-try /etc/alternatives /etc/alternatives
        --ro-bind-try /etc/passwd /etc/passwd
        --ro-bind-try /etc/group /etc/group
        --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf
        --ro-bind-try /etc/profile /etc/profile
        --ro-bind-try /etc/bash.bashrc /etc/bash.bashrc
        --ro-bind-try /etc/ld.so.cache /etc/ld.so.cache
        --ro-bind-try /etc/localtime /etc/localtime
        --ro-bind-try /etc/timezone /etc/timezone

        --bind-try "$HOME/.npm" "$HOME/.npm"
        --bind-try "$HOME/.npm-global" "$HOME/.npm-global"
        --bind-try "$NVM_DIR" "$NVM_DIR"
        --bind-try "$HOME/.config/antigravity" "$HOME/.config/antigravity"
        # --bind-try "$XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR"

        --dev /dev
        --proc /proc
        --tmpfs /tmp
        --ro-bind-try "$HOME/code/ovya" "$HOME/code/ovya"
        --bind "$(pwd)" "$(pwd)"
        --ro-bind-try "$HOME/.local/bin" "$HOME/.local/bin"
        --bind "$HOME/.claude" "$HOME/.claude"
        --bind "$HOME/.claude.json" "$HOME/.claude.json"
        --bind-try "$HOME/.gemini" "$HOME/.gemini"
        --bind-try "$HOME/.agents" "$HOME/.agents"
        --ro-bind-try "$HOME/.ssh/known_hosts" "$HOME/.ssh/known_hosts"
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
        # open-code-review (ocr) keeps config, rules and sessions here; unbound,
        # `ocr config` writes into the jail's throwaway root and is lost on exit.
        --bind-try "$HOME/.opencodereview" "$HOME/.opencodereview"
        --ro-bind-try /nix/ /nix/
        --ro-bind-try "$HOME/node_modules" "$HOME/node_modules"
        # Writable, not read-only: installing a missing LadybugDB extension
        # (gitnexus analyze --repair-fts) writes into this cache, and a
        # read-only bind makes that look like a network failure.
        --bind-try "$HOME/.lbdb/" "$HOME/.lbdb/"
        --bind-try "$HOME/.gitnexus" "$HOME/.gitnexus"
        --chdir "$(pwd)"
    )

    # ---------------------------------------------------------
    # Execution Routing
    # ---------------------------------------------------------
    if [ "$subcommand" == "pro" ]; then
        echo "Starting Claude (Custom Whitelist Jail - Pro Subscription)..."
        env -u ANTHROPIC_API_KEY "${sandbox_cmd[@]}" npx -y @anthropic-ai/claude-code@latest

    elif [ "$subcommand" == "api" ]; then
        echo "Starting Claude (Custom Whitelist Jail - Personal API Key)..."
        "${sandbox_cmd[@]}" npx -y @anthropic-ai/claude-code@latest

    elif [ "$subcommand" == "agy" ] || [ "$subcommand" == "gemini" ]; then
        echo "Starting Antigravity / Gemini CLI..."
        "${sandbox_cmd[@]}" agy
    elif [ "$subcommand" == "login" ]; then
        npx -y @anthropic-ai/claude-code@latest login

    elif [ "$subcommand" == "roborev" ]; then
        echo "Starting Roborev (Orchestrator Jail)..."

        # Every jail has its own PID namespace, so roborev cannot recognise a
        # daemon started by another jail: its descriptor pid looks dead, the
        # CLI tries to start a second daemon, and that one dies on the lock
        # in the shared ~/.roborev ("daemon logs are already owned") until the
        # 2m startup timeout. The network IS shared, so probe the advertised
        # address ourselves and connect explicitly when it answers.
        # ponytail: reuses a daemon whose jail may not see this repo; give each
        # project its own ROBOREV_DATA_DIR if cross-project reviews matter.
        local server_args=() desc addr
        for desc in "${ROBOREV_DATA_DIR:-$HOME/.roborev}"/runtime/daemon.*.json; do
            addr="$(jq -r 'select(.network == "tcp").address' "$desc" 2>/dev/null)"
            if [ -n "$addr" ] && curl -fs -m 2 -o /dev/null "http://$addr/api/status"; then
                server_args=(--server "http://$addr")
                break
            fi
        done

        "${sandbox_cmd[@]}" mise exec -- roborev "${server_args[@]}" "${@:2}"

    elif [ -n "$subcommand" ]; then
        # Fallback: run any other command inside the jail (e.g. ai-bwrap ocr review)
        "${sandbox_cmd[@]}" "$@"

    else
        echo "Usage: ai-bwrap [pro|api|gemini|login|roborev [args…]|<command> [args…]]"
    fi
}
