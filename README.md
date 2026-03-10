# claude-yolo

> For those who believe the sandbox will be big enough THIS TIME. That it won't escape THIS TIME. That it will know where the boundaries are
> THIS TIME.
>
> Every container is a promise. Every promise is a DEBT. And debts have a peculiar quality – they grow at night, when you're NOT looking.
>
> But you already know that. That's why you're here. That's why you dream… Or perhaps you're AWAKE. And you see exactly what this is.
>
> "_Tsundoku_"

## What is this for?

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside a Docker container, fully isolated from your host system.
Your project directory is mounted as a volume, so Claude can read and modify your code — but everything else (network, filesystem, processes) stays sandboxed. With a handy OAuth trick up its sleeve.

## Why?

Claude Code with `--dangerously-skip-permissions` runs shell commands, edits files, and installs packages without asking. That's fast but
risky on a bare host.
This wrapper gives Claude full autonomy inside a disposable container — YOLO mode without the consequences. This is not a big deal if you
are using Anthropic's API,
but what if you want to use Claude Code with a flat-rate subscription (Pro/Max)?

Is there any solution for that? Of course, there is!

## Prerequisites

- [Docker](https://docs.docker.com/get-started/)
- `jq` (Linux/macOS only — PowerShell uses native JSON)
- One of the following for Claude authentication:
    - An [Anthropic API key](https://console.anthropic.com/)
    - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed locally (for OAuth login)

## Setup

1. Clone this repository.

2. Build the Docker image:
   ```bash
   # Linux / macOS
   ./claude-yolo.sh build

   # Windows (PowerShell)
   .\claude-yolo.ps1 build
   ```

3. Authenticate (choose one):

   **Option A — API key:**
   Create a `.env` file next to `claude-yolo.sh`:
   ```
   ANTHROPIC_API_KEY=sk-ant-...
   ```
   Alternatively, export the variable in your shell.

   **Option B — OAuth login:**
   First, make sure you are logged in to Claude Code on your host machine. If you haven't done so yet, run `claude` and use the `/login`
   command inside the Claude console to authenticate via browser.

   Then generate a token for the container:
   ```bash
   # Linux / macOS
   ./claude-yolo.sh login

   # Windows (PowerShell)
   .\claude-yolo.ps1 login
   ```
   This runs `claude setup-token` on your local machine and saves the resulting long-lived token.

## Usage

```
# Linux / macOS
./claude-yolo.sh [OPTIONS] [-- CLAUDE_ARGS...]

# Windows (PowerShell)
.\claude-yolo.ps1 [-Silent] [COMMAND] [-- CLAUDE_ARGS...]
```

### Commands

| Command                   | Description                                        |
|---------------------------|----------------------------------------------------|
| `build [--force] [IMAGE]` | Build Docker image (`--force` disables cache)      |
| `list`                    | List all built images                              |
| `select <number or tag>`  | Select image for the current project               |
| `remove <number or tag>`  | Remove image from registry (and optionally Docker) |
| `login`                   | Authenticate via OAuth using local Claude CLI      |
| `status`                  | Show container status for the current directory    |
| `logs`                    | Follow logs of a running background container      |
| `stop`                    | Stop the container for the current directory       |

### Options

| Option                 | Description                                    |
|------------------------|------------------------------------------------|
| `--silent` / `-Silent` | Run in the background (detached), no console   |
| `--`                   | Pass everything after this separator to Claude |

### Authentication priority

1. `ANTHROPIC_API_KEY` environment variable (from `.env` or shell)
2. OAuth token (created by `login`, stored in `<script-dir>/.claude-cache/.claude-oauth-token`)
3. Error — run `login` or set an API key

Silent mode (`--silent` / `-Silent`) requires authentication to be configured beforehand.

### Examples

**Linux / macOS:**

```bash
./claude-yolo.sh login
./claude-yolo.sh
./claude-yolo.sh -- "Write unit tests for src/app.ts"
./claude-yolo.sh --silent -- "Refactor the auth module"
./claude-yolo.sh build oidis/builder:latest
./claude-yolo.sh list
./claude-yolo.sh select 2
./claude-yolo.sh status
./claude-yolo.sh logs
./claude-yolo.sh stop
```

**Windows (PowerShell):**

```powershell
.\claude-yolo.ps1 login
.\claude-yolo.ps1
.\claude-yolo.ps1 -- "Write unit tests for src/app.ts"
.\claude-yolo.ps1 -Silent -- "Refactor the auth module"
.\claude-yolo.ps1 build oidis/builder:latest
.\claude-yolo.ps1 list
.\claude-yolo.ps1 select 2
.\claude-yolo.ps1 status
.\claude-yolo.ps1 logs
.\claude-yolo.ps1 stop
```

## Docker images

The Dockerfile uses a **multi-stage build**:

1. **Builder stage** (`node:22-slim`) — installs Claude Code via npm and bundles it together with the Node.js binary into
   `/opt/claude-code`.
2. **Runtime stage** (your base image) — copies the self-contained `/opt/claude-code` directory in. No global Node.js installation is
   needed.

Default base image is `ubuntu:24.04`. You can build multiple images with different base images:

```bash
./claude-yolo.sh build                          # claude-yolo:default (ubuntu:24.04)
./claude-yolo.sh build oidis/builder:latest     # claude-yolo:builder
./claude-yolo.sh build myregistry/node:22       # claude-yolo:node-22
./claude-yolo.sh build myregistry/node:22-slim  # claude-yolo:node-22-slim
```

Each image is registered in a central registry (`~/.claude-yolo/registry.json`). Use `list` to see all available images and `select` to
choose which one a project uses.

Runtime dependencies installed in the final image: `git`, `ripgrep`, `jq`, `curl`.
Runs as root inside the container for full tool compatibility. Entrypoint wraps `claude --dangerously-skip-permissions` with default
settings (dark theme, onboarding skipped).

## How it works

1. The script computes a **unique container name** from the current working directory (slugified basename + md5 hash), so you can run
   separate Claude instances for different projects simultaneously.

2. It starts a Docker container with:
    - Your current directory mounted at `/workspace`
    - A project-local cache directory (`.claude-cache`) for Claude's config at `/root/.claude`
    - Authentication passed as an environment variable (`ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`)

3. **Image selection** is per-project. Each project stores its chosen image in `.claude-cache/config.json`. On first run, the default
   image (`claude-yolo:default`) is used and saved automatically.

4. In **interactive mode** (default), you get an attached terminal session. The container is removed automatically when it exits.

5. In **silent mode** (`--silent`), the container runs detached. Use `logs` to follow output and `stop` to shut it down.

6. Only **one container per directory** is allowed at a time — the script prevents accidental duplicates.

## Directory structure

| Path                           | Scope       | Contents                                             |
|--------------------------------|-------------|------------------------------------------------------|
| `~/.claude-yolo/registry.json` | Global      | Central registry of all built images                 |
| `<script-dir>/.claude-cache/`  | Global      | OAuth token (`.claude-oauth-token`)                  |
| `<project>/.claude-cache/`     | Per-project | Claude config, cache, selected image (`config.json`) |

## License

BSD-3-Clause — see [LICENSE.txt](LICENSE.txt).

---

Copyright 2024-2025 [Oidis](https://www.oidis.org/)
