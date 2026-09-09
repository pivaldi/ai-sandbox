# AI CLI Custom Sandbox (Gemini & Claude)

A specialized, security-focused wrapper for running the [Google Gemini CLI](https://www.npmjs.com/package/@google/gemini-cli) and [Anthropic Claude Code](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview) against your projects **without handing the agent your whole machine**.

It ships **two independent ways to sandbox** the same agents, so you can trade isolation strength for speed:

* **`ai-sandbox` — Docker mode.** Runs the CLIs inside a versioned Docker image with your UID/GID mapped and toolchains cached in Docker volumes. Strongest isolation; heavier.
* **`ai-bwrap` — Bubblewrap mode.** Runs the CLIs natively on your host via `npx`, inside a [bubblewrap](https://github.com/containers/bubblewrap) namespace jail that whitelists only the current project directory plus a curated set of config/toolchain paths. No Docker, no image build; near-instant startup.

Both modes solve the same friction points of local AI-agent development — file ownership, toolchain caching, and **blast radius** — while keeping the rest of your host out of the agent's reach.

---

## Choosing a Mode

|  | `ai-sandbox` (Docker) | `ai-bwrap` (Bubblewrap) |
| --- | --- | --- |
| **Isolation** | Full container: separate rootfs, mapped UID/GID | Namespace + filesystem whitelist; shares the host kernel, runs as **you** |
| **Startup** | Builds a versioned image on first run / version bump | Instant; `npx` fetches the CLI on demand |
| **Toolchains** | `mise` (Go/Node/Python…) baked in and cached in Docker volumes | Reuses your host `mise`/`cargo`/`go`/`nix` (mostly read-only) |
| **Prerequisites** | Docker, `jq`, `curl` | `bwrap` (bubblewrap) and Node/`npx` on the host |
| **Extras** | GitNexus, roborev, `everything-claude-code` preinstalled | `roborev` via your host `mise` |
| **Paths** | Your real `$HOME` and project path, reproduced inside the container | Your real `$HOME` and project path (bound in place) |
| **Best for** | Reproducible env, less-trusted work | Fast iteration on your own machine |

Both give the agent access to **only the current directory** (`$(pwd)`) plus the credentials and caches it needs — everything else on your host is invisible.

---

## Key Features

* **Dual AI support:** run both `gemini` and `claude` in either sandbox mode.
* **Two isolation modes:** heavyweight Docker or lightweight bubblewrap, same subcommands.
* **Smart billing router:** swap between your Claude Pro subscription and Anthropic API key per-invocation, no config edits. `pro` deliberately strips `ANTHROPIC_API_KEY` so a subscription session can't silently fall back to metered billing.
* **Dynamic UID/GID mapping (Docker):** files the agent creates are owned by your host user, so you can edit them in Emacs or VSCode without `sudo`. (Bubblewrap already runs as you.)
* **Persistent toolchain caching:** Docker mode caches [Mise](https://mise.run/) SDKs in a volume; bubblewrap mode reuses the toolchains already installed on your host.
* **Interchangeable config:** both modes reproduce your host's `$HOME` and project paths, so the shared `~/.claude` (logins, plugins, hooks, GitNexus index) works identically whichever sandbox you launch.
* **Auto-updating (Docker):** the wrapper pings NPM for the latest Gemini/Claude releases and rebuilds the local image *only* when the version actually changes.

---

## Available Tools

* **Claude Code** & **Gemini CLI**
* **Mise:** the runtime executor — auto-pins the latest fully-installed version of every tool as the global default.
* **[roborev](https://roborev.io):** continuous code review for AI coding agents.
* **[GitNexus](https://github.com/abhigyanpatwari/GitNexus):** indexes any codebase into a knowledge graph so AI agents never miss context (registered as an MCP server in Docker mode).

*In Docker mode the entrypoint also bootstraps the [`everything-claude-code`](https://github.com/affaan-m/everything-claude-code) plugin marketplace.*

---

## Installation

**1. Clone this repository** anywhere on your machine:

```bash
git clone https://github.com/pivaldi/ai-sandbox.git .
```

**2. (Docker mode) Make the entrypoint executable:**

```bash
cd ai-sandbox && chmod +x docker-entrypoint.sh
```

**3. Create a symbolic link** from the `ai-sandbox` folder to `~/.ai-sandbox`:

```bash
ln -s "$(pwd)" ~/.ai-sandbox
```

**4. Install the prerequisites for the mode(s) you want:**

* **Docker mode:** Docker, `jq`, and `curl`.
* **Bubblewrap mode:** `bubblewrap` (e.g. `sudo apt install bubblewrap`) and Node.js (which provides `npx`).

**5. Set your global environment variables** (place these in your `~/.bashrc` or `~/.zshrc`):

```bash
export GEMINI_API_KEY="your-gemini-key"
export ANTHROPIC_API_KEY="sk-ant-your-private-key"
```

*Note: exporting your Anthropic key globally is safe — the `pro` subcommand deliberately omits it, so it never interferes with subscription billing.*

**6. Source the script from your shell profile** (`~/.bashrc` or `~/.zshrc`). This one file defines **both** the `ai-sandbox` and `ai-bwrap` functions:

```bash
echo 'source ~/.ai-sandbox/ai-sandbox.sh' >> ~/.bashrc
```

**7. Reload your shell:**

```bash
source ~/.bashrc
```

---

## Usage

Navigate to any project directory on your host machine, then pick a mode.

### Docker mode — `ai-sandbox`

| Command | Description |
| --- | --- |
| `ai-sandbox login` | Launches the interactive web flow to authenticate your Claude Pro/Max subscription. |
| `ai-sandbox pro` | Starts Claude Code on your **Pro subscription** (strips out `ANTHROPIC_API_KEY`). |
| `ai-sandbox api` | Starts Claude Code on your **personal API key** (reads `ANTHROPIC_API_KEY` from your environment). |
| `ai-sandbox gemini` | Starts the Google Gemini CLI environment. |
| `ai-sandbox bash` | Drops you into an interactive bash shell inside the container as your local user. |

On first run (or after a CLI version bump) the script builds a versioned image such as `ai-sandbox:gemini-<v>-claude-<v>` before launching.

### Bubblewrap mode — `ai-bwrap`

`ai-bwrap` auto-sources `./.env` from the project directory first, then runs the CLI inside the jail via `npx`.

| Command | Description |
| --- | --- |
| `ai-bwrap login` | Runs `claude login` **outside** the jail to complete the OAuth flow. |
| `ai-bwrap pro` | Starts Claude Code on your **Pro subscription** (strips out `ANTHROPIC_API_KEY`). |
| `ai-bwrap api` | Starts Claude Code on your **personal API key** (from `./.env` or your environment). |
| `ai-bwrap gemini` | Starts the Google Gemini CLI (requires `GEMINI_API_KEY`). |
| `ai-bwrap roborev [args…]` | Runs roborev inside the jail via `mise exec`, forwarding any extra arguments. |

---

## What happens under the hood?

**The auto-updater (Docker).**
The script queries NPM for the newest `@google/gemini-cli` and `@anthropic-ai/claude-code`, derives an image tag like `ai-sandbox:gemini-<v>-claude-<v>`, and rebuilds from the local `Dockerfile` in `~/.ai-sandbox` **only if that tag doesn't already exist**. Inside the container the entrypoint maps your host UID/GID, activates `mise`, pins the latest installed version of every tool as the global default, and trusts the mounted project directory.

**One set of paths, both modes.**
Docker mode reproduces your host's paths rather than inventing container-only ones: your project is mounted at its real path (not `/workspace`) and `$HOME` is your actual home (not `/home/gemini`), with the container user renamed to your username and mapped to your UID/GID.

This matters because `~/.claude`, `~/.claude.json` and `~/.gitnexus` are shared between the two modes, and the tools that write there record **absolute** paths — plugin `installPath`, marketplace `installLocation`, hook commands, Claude's project-scoped settings, and GitNexus's repo registry. If the two modes disagreed about where your home or your project lives, whichever ran last would rewrite those paths and break the other. Keeping the paths identical means one login, one plugin set, and one GitNexus index shared by both modes. The one deliberate exception is GitNexus's registry: `~/.gitnexus` is **not** shared, because `registry.json` is small mutable state with no locking, and a container MCP server and a host one sharing it silently overwrite each other's registrations. Docker mode gets its own `~/.gitnexus-docker` instead, and the entrypoint registers the project on start. Only the pointer file is duplicated — the index itself lives in the repo's own `.gitnexus/` and is shared through the project mount.

**The bubblewrap jail.**
`ai-bwrap` builds a single `bwrap` invocation that does `--unshare-all` and then re-adds only the network (`--share-net`). It read-only-binds the system directories the CLIs actually need (`/usr`, `/lib`, `/etc/ssl/certs`, `/etc/resolv.conf`, …) and read-write-binds **only** the current project plus a short whitelist (`~/.claude`, `~/.claude.json`, `~/.gemini`, roborev config, the Go build cache, the LadybugDB extension cache). It does **not** bind `/etc` wholesale or your whole `$HOME` — anything not on the list simply doesn't exist inside the jail.

---

## Security Note

Neither mode is a VM. Be honest with yourself about what they do and do not protect:

* **Your project directory is writable inside the sandbox.** `$(pwd)` is mounted/bound read-write in *both* modes. A misbehaving agent can still rewrite, delete, or exfiltrate files in the current project. Commit often; do not point this at a directory you cannot afford to lose.
* **Credentials are exposed to the agent.** `~/.claude`, `~/.claude.json`, and `~/.gemini` are mounted/bound so the CLIs can authenticate. The `pro` subcommand omits `ANTHROPIC_API_KEY`, but the Claude OAuth token in `~/.claude` is always reachable.
* **Bubblewrap shares your kernel and runs as you.** `ai-bwrap` is a namespace + filesystem jail, not a container. Everything on its read-write whitelist (project dir, credential dirs, roborev config, Go build cache) is fair game; only paths *outside* the whitelist are hidden. For genuinely untrusted code, prefer Docker mode — or a disposable VM.
* **Trust boundary is the prompt, not the sandbox.** The isolation guards against the agent doing something dumb on its own. It does not guard against you pasting a prompt that instructs it to. Review tool calls when running with `--dangerously-skip-permissions` or equivalent.

If you need stronger isolation (e.g. running fully untrusted code), run the whole stack inside a disposable VM rather than on your dev host.

---

## Rebuild the Docker Image manually

If you need to force a rebuild of the Docker image without waiting for an NPM version bump, run:

```bash
export GEMINI_VERSION="$(curl -s https://registry.npmjs.org/@google/gemini-cli/latest | jq -r '.version')" && \
export CLAUDE_VERSION="$(curl -s https://registry.npmjs.org/@anthropic-ai/claude-code/latest | jq -r '.version')" && \
    docker build \
        --build-arg GEMINI_VERSION="$GEMINI_VERSION" \
        --build-arg CLAUDE_VERSION="$CLAUDE_VERSION" \
        -t "ai-sandbox:gemini-${GEMINI_VERSION}-claude-${CLAUDE_VERSION}" \
        -t "ai-sandbox:latest" ~/.ai-sandbox
```

---

## A Cherry for Emacs Users

Because both the Claude and Gemini CLIs use complex Terminal User Interfaces (TUIs) with rich ANSI escape sequences, standard Emacs shells (`M-x shell` or `M-x eshell`) will mangle the output.

To run these sandboxes flawlessly inside Emacs, use **[vterm](https://github.com/akermu/emacs-libvterm)** (a fully-fledged terminal emulator compiled as a dynamic module).

### Quick Elisp Integration

If you use `vterm`, add this interactive function to your `init.el` to spawn a sandbox session from anywhere, with an interactive menu to pick your mode:

```elisp
(defun ai-sandbox-launch (mode)
  "Launch ai-sandbox in a dedicated vterm buffer.
Select MODE (pro, api, gemini, bash, login) interactively."
  (interactive
   (list (completing-read "Select AI Sandbox Mode: "
                          '("pro" "api" "gemini" "bash" "login"))))
  (let* ((buf-name (format "*ai-sandbox-%s*" mode)))
    ;; Open vterm in a new window/buffer
    (vterm buf-name)
    ;; Send the command to the active vterm process
    (vterm-send-string (format "ai-sandbox %s\n" mode))))
```

**Usage:** type `M-x ai-sandbox-launch`, select `pro` or `api`, and you land straight in the secure agent environment without leaving Emacs. Swap `ai-sandbox` for `ai-bwrap` in the format string if you prefer the lightweight bubblewrap jail.
