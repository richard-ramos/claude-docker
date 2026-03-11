# Dockerized Claude Code

Run Claude Code inside a Docker container with full permissions (`--dangerously-skip-permissions`). Claude can freely install packages, run commands, and use tools inside the container without affecting your host system. Only explicitly mounted folders are accessible.

## Install

```bash
git clone https://github.com/iurimatias/claude-docker.git ~/.claude-docker
cd ~/.claude-docker
sudo ln -sf "$(pwd)/claude.sh" /usr/local/bin/claude-docker
```

Or, if you prefer not to use `sudo`, add an alias to your shell profile (`~/.zshrc`, `~/.bashrc`, etc.):

```bash
echo 'alias claude-docker="$HOME/.claude-docker/claude.sh"' >> ~/.zshrc
source ~/.zshrc
```

Then just run `claude-docker` from any directory.

## Setup

The image will be built automatically on first run and **rebuilt automatically** whenever the Dockerfile changes. Claude Code will prompt you to log in on first use (OAuth). Your credentials are persisted in `~/.claude` so you only need to log in once.

Alternatively, if you have an Anthropic API key (to use your own API credits instead of a Claude Code subscription), set it before running:

```bash
export ANTHROPIC_API_KEY=your-key-here
claude-docker
```

## Usage

```bash
# Mount current directory
claude-docker

# Mount a specific folder
claude-docker /path/to/project

# Mount multiple folders
claude-docker /path/to/project /path/to/data

# One-shot prompt (non-interactive)
claude-docker /path/to/project -- -p "fix the tests"
```

When run without extra arguments, you get an interactive Claude Code CLI session in your terminal. Type your requests, chat back and forth, and exit with `/exit` or Ctrl+C.

## Options

| Flag | Description |
|------|-------------|
| `--memory SIZE` | Set container memory limit (e.g. `8g`, `4096m`) |
| `--gpu` | Enable GPU passthrough (`--gpus all`) |
| `--no-network` | Disable network access (fully offline sandbox) |
| `--worktree NAME` | Run in a git worktree (isolated branch + working dir) |
| `--worktree-base DIR` | Base directory for worktrees (default: parent of project) |
| `--sessions` | List and manage saved sessions |
| `--rebuild` | Force rebuild the Docker image |
| `-h, --help` | Show help message |

```bash
# Run with 8GB memory limit
claude-docker --memory 8g /path/to/project

# GPU-enabled session
claude-docker --gpu --memory 16g .

# Fully offline/sandboxed (no network)
claude-docker --no-network .

# Isolated worktree session
claude-docker --worktree feature-auth

# Force rebuild the image
claude-docker --rebuild
```

## How Mounting Works

- **Single folder**: mounted directly at `/workspace`
- **Multiple folders**: each mounted at `/workspace/<folder-name>`

## What Claude Can Do Inside the Container

Claude has full access inside the container and can install anything it needs at runtime, for example:

- `apt-get install` system packages
- `npm install` / `pip install` dependencies
- `nix-env -i` packages (Nix is pre-installed)
- Install and run browsers via Playwright (`npx playwright install --with-deps chromium`)

These installs are ephemeral — the container is removed after each session, so nothing persists between runs.

## Auto-Resume

Sessions are automatically tracked per directory. When Claude exits (normally or due to a crash), the session ID is saved. Next time you run from the same directory, you'll be prompted to resume:

```
Found previous session for /path/to/project
Session: 33ddab83-7740-4709-bc84-c561b4092a21
Resume? [Y/n]
```

Press Enter to resume, or `n` to start fresh.

## Session Management

List and prune saved sessions:

```bash
claude-docker --sessions
```

```
Saved sessions:

  1) 33ddab83-7740-4709-bc84-c561b4092a21  (2h ago)
  2) a1b2c3d4-e5f6-7890-abcd-ef1234567890  (3d ago)

Delete sessions? [enter numbers, 'all', or empty to cancel]
```

## Git Worktrees

Use `--worktree` to run Claude in an isolated working directory with its own branch. This lets you run parallel sessions on different tasks without conflicts.

```bash
# Named worktree — creates ../project--feature-auth/ with branch feature-auth
claude-docker --worktree feature-auth

# Auto-named worktree — generates a timestamped name
claude-docker --worktree

# Combine with other flags
claude-docker --worktree bugfix-123 --memory 8g /path/to/project
```

The mounted workspace must be a git repo. The worktree is created on the host at `../<repo>--<name>` as a sibling of the original project folder. Use `--worktree-base` to place worktrees elsewhere:

```bash
# All worktrees go into ~/worktrees/
claude-docker --worktree feature-auth --worktree-base ~/worktrees
```

### Post-worktree hook

If `.claude-docker/post-worktree.sh` exists in the repo, it runs on the host after the worktree is created (before the container starts). This is useful for things like initializing git submodules:

```bash
#!/usr/bin/env bash
git submodule update --init --recursive
```

## Sharing Images and Files

Drag-and-drop doesn't work directly because the host file path doesn't exist inside the container. To share images or files with Claude, use the `~/claude-drops` folder:

```bash
mkdir -p ~/claude-drops
```

Copy or move files there, then reference them in Claude by their full path (e.g., `~/claude-drops/screenshot.png`). The folder is automatically mounted read-only when it exists.

## Auto-Rebuild

The image is rebuilt automatically when the Dockerfile changes — no need to manually run `docker build`. Use `--rebuild` to force a rebuild at any time.

## Tips

- Press **Ctrl+J** to insert a newline in the input field (instead of submitting).
