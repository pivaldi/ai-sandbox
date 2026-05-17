# AI CLI Custom Sandbox (Gemini & Claude)

A specialized, highly secure, dual-container environment for both the [Google Gemini CLI](https://www.npmjs.com/package/@google/gemini-cli) and [Anthropic Claude Code](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview).

This project solves the biggest friction points of local AI agent development: file permissions, toolchain caching, and **security radius**. By separating your development environment from the agent's web-browsing and execution environment using a secure MCP (Model Context Protocol) bridge, it keeps your host machine safe while giving the AI unlimited power.

## The Architecture: "Brain" and "Hands"

Running AI agents natively on your host OS gives them dangerous access to your entire filesystem. This wrapper implements a **Dual-Container Architecture** to completely isolate the execution context while maintaining perfect UID/GID mapping for your IDE.

| Component | Container Name | Role | Capabilities & Contents |
| --- | --- | --- | --- |
| **The Brain** | `ai-sandbox` (Dynamic Version) | Orchestration & Tooling | Runs Claude/Gemini CLI. Contains `mise` toolchains (Go, Node, Python), GitNexus, and your mapped UID/GID. Completely safe to run code here. |
| **The Hands** | `aio-sandbox` (Agent-Infra) | Web Browsing & Execution | A disposable "Hazmat Chamber" running in the background. Contains a Chromium browser, VSCode Server, VNC, and Jupyter. Bridged to the "Brain" via MCP. |

---

## Key Features

* **Dual AI Support:** Run both `gemini` and `claude` commands within the same isolated ecosystem.
* **Smart Billing Router:** Seamlessly swap between billing by Claude Pro subscription or Anthropic API key without editing configurations.
* **Dynamic UID/GID Mapping:** Prevents the "root ownership" trap. Files created by the agents belong to your local host user, so you can edit them in Emacs or VSCode without needing `sudo`.
* **Persistent Toolchain Caching:** Integrates seamlessly with [Mise](https://mise.run/). SDKs downloaded by the agents are cached in a Docker volume, making subsequent boots lightning fast.
* **Visual Observability:** Watch the AI browse the web or execute complex tasks in real-time via the built-in VNC and Jupyter Web UI (`http://localhost:8181`).
* **Auto-Updating:** The wrapper script automatically pings NPM for the latest CLI releases and rebuilds your local Docker image dynamically before launching.

---

## Available Tools

* **Claude Code** & **Gemini CLI**
* **Mise:** The ultimate runtime executor (auto-pins global tools based on your project).
* **[roborev](https://www.google.com/search?q=https://github.com/roborev):** Continuous code review for AI coding agents.
* **[Gitnexus](https://github.com/abhigyanpatwari/GitNexus):** Indexes any codebase into a knowledge graph so AI agents never miss context.
* **[aio-sandbox](https://github.com/agent-infra/sandbox):** ByteDance's All-in-One environment that provides Browser, Shell, File manager, and MCP servers natively.

---

## Installation

**1. Clone this repository** anywhere on your machine:

```bash
git clone https://github.com/pivaldi/ai-sandbox.git .
```

**2. Make the entrypoint executable:**

```bash
cd ai-sandbox && chmod +x docker-entrypoint.sh
```

**3. Create a symbolic link** from the `ai-sandbox` folder to `~/.ai-sandbox`:

```bash
ln -s "$(pwd)" ~/.ai-sandbox
```

**4. Set your global environment variables** (Place this in your `~/.bashrc` or `~/.zshrc`):

```bash
export GEMINI_API_KEY="your-gemini-key"
export ANTHROPIC_API_KEY="sk-ant-your-private-key"
```

*Note: Thanks to Docker's native environment isolation, exporting your Anthropic key globally is 100% safe. It will not override or interfere with your Pro Subscription billing when using the pro command.*

**5. Source the script from your shell profile** (`~/.bashrc` or `~/.zshrc`):

```bash
echo 'source ~/.ai-sandbox/ai-sandbox.sh' >> ~/.bashrc
```

**6. Reload your shell:**

```bash
source ~/.bashrc
```
---

## Usage

Navigate to any project directory on your host machine. You can now use the ai-sandbox CLI router to control the environment:

| Command | Description |
| --- | --- |
| `ai-sandbox login` | Launches the interactive web flow to authenticate your Claude Pro/Max subscription. |
| `ai-sandbox pro` | Starts Claude Code using your **Pro Subscription** (purposely strips out your API key). |
| `ai-sandbox api` | Starts Claude Code using your **Personal API Key** (loads from your `.env` file). |
| `ai-sandbox gemini` | Starts the Google Gemini CLI environment. |
| `ai-sandbox bash` | Drops you into an interactive bash shell inside the container as your local user. |
| `ai-sandbox stop` | Gracefully stops and removes the background `aio-sandbox` "Hazmat Chamber". |

### Observability: The Web UI

When you run any command, the script automatically spins up the `aio-sandbox` in the background. Open your web browser and navigate to:
**`http://localhost:8181`**

From here, you can open the **VNC tab** to literally watch Claude navigate the web, or open the **VSCode Server** to inspect the files inside the container in real-time.

---

## What happens under the hood?

**The Auto-Updater:**
The script checks `NPM` for the newest `@google/gemini-cli` and `@anthropic-ai/claude-code` versions. If your local image is outdated, it dynamically builds it using the `Dockerfile` in `~/.ai-sandbox`.

**The Daemon:**
The script checks if `aio-sandbox` is running via Docker. If not, it spins it up in detached mode, exposing port `8181` to your host and mounting your `$(pwd)` to `/workspace`.

**The Bridge (Docker-from-Docker):**
When the `ai-sandbox` container boots, it mounts `/var/run/docker.sock`. Because the `gemini` user is dynamically added to the host's Docker group, Claude can execute `MCP` commands *across* the container boundary.

When Claude calls `aio-sandbox-shell`, it essentially runs `docker exec -i aio-sandbox npx @agent-infra/mcp-server-shell`. This keeps your carefully crafted `mise` toolchains safe in the "Brain" container, while offloading destructive bash commands or heavy web scraping to the disposable "Hands" container.

---

## Security Note

The dual-container split is a **risk reduction**, not a sandbox in the strict sense. Be honest with yourself about what it does and does not protect:

* **Docker socket is root-equivalent.** The Brain container mounts `/var/run/docker.sock` so it can `docker exec` into the Hands. Anything (or anyone) with write access to that socket can launch a privileged container that mounts `/` from the host — i.e. it can become root on your machine. Treat the Brain container as if it were running with host root.
* **The Hands container is disposable, the Brain container is not.** Destructive shell commands and untrusted browser activity should be routed through `aio-sandbox-shell` / `aio-sandbox-browser` so they land in the Hands container, which you can `ai-sandbox stop` and recreate. Running the same command directly inside the Brain pollutes your toolchain and credentials surface.
* **Your project directory is bind-mounted into both containers.** `$(pwd)` is mounted to `/workspace` in the Brain *and* in the Hands. An agent that misbehaves can still rewrite, delete, or exfiltrate files in the current project regardless of which container it runs in. Commit often; do not point this at a directory you cannot afford to lose.
* **Credentials live in the Brain.** `~/.claude`, `~/.claude.json`, `~/.gemini`, and (in `api` mode) `ANTHROPIC_API_KEY` are exposed inside the Brain container. The `pro` subcommand deliberately omits `ANTHROPIC_API_KEY` so a subscription session cannot leak the key, but the Claude OAuth token in `~/.claude` is always reachable.
* **Port 8181 is bound to localhost only by default.** The Hands container exposes its web UI on `localhost:8181`. Do **not** publish this port on a public interface — VNC + a shell MCP server on an open port is a remote root shell with extra steps.
* **Trust boundary is the prompt, not the container.** The isolation protects against an agent doing something dumb. It does not protect against you pasting a prompt that instructs the agent to do something dumb. Review tool calls when running `--dangerously-skip-permissions` or equivalent.

If you need stronger isolation (e.g. running fully untrusted code), run the whole stack inside a disposable VM rather than on your dev host.

---

## Rebuild the Image manually

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

Yes, this is a very important detail to include! Because both `claude-code` and `gemini-cli` use advanced terminal UIs (rich colors, spinners, keyboard interception, and complex ANSI escape sequences), standard Emacs line-mode buffers like `M-x shell` or `M-x eshell` will mangle the output completely.

To use this seamlessly in Emacs, you must use a fully capable terminal emulator package. **`vterm`** is the gold standard for this.

Here is the final note you can append to the bottom of your `README.md` to help yourself (and any other Emacs users who find your repo):

## A Cherry for Emacs Users

Because both the Claude and Gemini CLIs use complex Terminal User Interfaces (TUIs) with rich ANSI escape sequences, standard Emacs shells (`M-x shell` or `M-x eshell`) will mangle the output.

To run `ai-sandbox` flawlessly inside Emacs, you should use **[vterm](https://github.com/akermu/emacs-libvterm)** (a fully-fledged terminal emulator compiled as a dynamic module).

### Quick Elisp Integration

If you use `vterm`, you can add this interactive function to your `init.el` to instantly spawn an AI sandbox session from anywhere. It even provides an interactive menu to choose your billing mode!

```elisp
(defun ai-sandbox-launch (mode)
  "Launch ai-sandbox in a dedicated vterm buffer.
Select MODE (pro, api, gemini, bash, login, stop) interactively."
  (interactive
   (list (completing-read "Select AI Sandbox Mode: "
                          '("pro" "api" "gemini" "bash" "login" "stop"))))
  (let* ((buf-name (format "*ai-sandbox-%s*" mode)))
    ;; Open vterm in a new window/buffer
    (vterm buf-name)
    ;; Send the command to the active vterm process
    (vterm-send-string (format "ai-sandbox %s\n" mode))))
```

**Usage:** Just type `M-x ai-sandbox-launch`, select `pro` or `api`, and you will be dropped straight into the secure agent environment without ever leaving Emacs.
