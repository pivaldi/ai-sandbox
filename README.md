# AI CLI Custom Sandbox (Gemini & Claude)

A specialized, auto-updating Docker environment for both the [Google Gemini CLI](https://www.npmjs.com/package/@google/gemini-cli) and [Anthropic Claude Code](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview).

This project wraps the official Gemini sandbox image and enhances it to solve common friction points when using AI agents for local development, specifically around file permissions, toolchain caching, and environment persistence across both major AI CLI tools.

## Key Features

  * **Dual AI Support:** Run both `gemini` and `claude` commands within the same isolated environment.
  * **Dynamic UID/GID Mapping:** Prevents the "root ownership" trap. Files created or modified by the AI agents belong to your local host user, so you can edit them in your IDE without needing `sudo`.
  * **Persistent Toolchain Caching:** Integrates seamlessly with [Mise](https://mise.run/). SDKs (like Go, Node, or Python) downloaded by the agents are cached in a Docker volume, making subsequent container boots lightning fast.
  * **Auto-Updating:** The wrapper script automatically pings NPM for the latest Gemini CLI release. If a new version exists, it dynamically rebuilds your local Docker image before launching, ensuring both Gemini and Claude Code are kept up-to-date.
  * **Persistent Authentication:** Mounts your host's `~/.gemini` directory, `~/.claude` directory, and `~/.claude.json` so you never have to re-authenticate either CLI inside the container.

## Repository Structure

```text
.
├── Dockerfile             # Builds the custom sandbox (installs Claude Code via npm)
├── docker-entrypoint.sh   # Handles dynamic user creation and drops privileges via gosu
└── ai-sandbox.sh        # The bash wrapper script to auto-build and launch the sandbox
```

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

**4. Add the wrapper function to your shell profile** (`~/.bashrc` or `~/.zshrc`):
Open the `ai-sandbox.sh` file from this repository, copy the bash function (`ai-sandbox`), and paste it into your profile.
Don't forget to change the value of `GEMINI_API_KEY` to your own.

**5. Reload your shell:**

```bash
source ~/.bashrc
```

## Usage

Navigate to any project directory on your host machine that you want the AI agents to work on.

Simply run:

```bash
ai-sandbox
```

### What happens under the hood?

1.  The script checks NPM for the newest `@google/gemini-cli` version.
2.  It checks if you have a local Docker image built for that specific version. If not, it builds it using the `Dockerfile` in `~/.ai-sandbox` (which also globally installs `@anthropic-ai/claude-code`).
3.  It boots the container, mounting your current working directory (`$(pwd)`) to `/workspace` and persisting your authentication files.
4.  It dynamically creates a user inside the container matching your host's UID/GID.
5.  It drops you into an interactive terminal where both the `gemini` and `claude` CLIs are fully authenticated and ready to code.

## Typical AI Workflow With Mise

Because this sandbox has `mise` baked in, you can place a `mise.toml` in your project root. When the agent boots, give it a prompt like this:

> *"Hello! Please run `mise install` to bootstrap the toolchain. Then, review the codebase and implement [feature]."*

The agent will instantly download the exact versions of Go, Node, or CLI tools your project needs into the persistent `gemini-mise-cache` volume, ensuring its environment perfectly mirrors yours.

## Rebuild the Image

For some reason, you may want to force the re-build of the Docker image…
Simply launch this command:

```bash
export GEMINI_VERSION="$(curl -s https://registry.npmjs.org/@google/gemini-cli/latest | jq -r '.version')" && \
export CLAUDE_VERSION="$(curl -s https://registry.npmjs.org/@anthropic-ai/claude-code/latest | jq -r '.version')" && \
    docker build \
        --build-arg GEMINI_VERSION="$GEMINI_VERSION" \
        --build-arg CLAUDE_VERSION="$CLAUDE_VERSION" \
        -t "ai-sandbox:gemini-${GEMINI_VERSION}-claude-${CLAUDE_VERSION}" ~/.ai-sandbox
```
