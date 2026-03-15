# claude-sandbox

Run Claude Code in a disposable devcontainer with full permissions. Clones one or more GitHub repos into an isolated Docker environment, then drops you into a shell (or runs Claude non-interactively).

Containers are automatically cleaned up on exit.

## Prerequisites

- Docker Desktop
- [devcontainer CLI](https://github.com/devcontainers/cli): `npm install -g @devcontainers/cli`
- GitHub SSH access configured (`~/.ssh`)
- `gh` CLI authenticated (`gh auth login`)

## Setup

```bash
git clone git@github.com:Henrey428/claude-sandbox.git
cd claude-sandbox
chmod +x claude-sandbox
```

### First-time authentication

Claude Code credentials don't transfer from the macOS Keychain into the container automatically. On your first run, authenticate inside the container:

```bash
claude login
```

This saves credentials to `~/.claude/.credentials.json` on your host (via bind mount), so all future containers pick them up automatically.

## Usage

```
claude-sandbox --main org/repo[@branch] [--repo org/repo[@branch] ...] [OPTIONS]
```

### Options

| Flag | Description |
|------|-------------|
| `--main org/repo[@branch]` | Main repo (required). Append `@branch` for a specific branch. |
| `--repo org/repo[@branch]` | Additional repo. Repeat for multiple. |
| `--claude "prompt"` | Run Claude non-interactively with this prompt. |
| `--dir /path` | Override the temp project directory. |
| `-h, --help` | Show help. |

### Examples

```bash
# Single repo — drops into an interactive shell
./claude-sandbox --main myorg/api-service

# Multi-repo with branches
./claude-sandbox \
  --main myorg/api-service@feature-x \
  --repo myorg/shared-lib@feature-x

# Different branches per repo
./claude-sandbox \
  --main myorg/api-service@fix-auth \
  --repo myorg/shared-lib@v2-refactor \
  --repo myorg/infra-config@staging

# Non-interactive — run Claude with a prompt and exit
./claude-sandbox \
  --main myorg/api-service@fix-auth \
  --repo myorg/shared-lib@fix-auth \
  --claude "Fix the auth middleware using the updated types from shared-lib"
```

## Inside the container

### Claude Code

Claude runs with `--dangerously-skip-permissions` (auto-approved for all tools). In interactive mode, just type `claude` — the flag is aliased automatically.

### Workspace layout

Repos are cloned into `repos/` inside the workspace directory, with `main` symlinked to the main repo:

```
/workspaces/<sandbox-name>/
├── main -> repos/api-service     # symlink to main repo
└── repos/
    ├── api-service/              # --main repo
    └── shared-lib/               # --repo
```

### Helper commands

| Command | Description |
|---------|-------------|
| `ws-status` | Show all repos with current branches |
| `ws-cd <repo>` | Jump to a repo directory |
| `ws-main` | Jump to the main repo |
| `wt-add <branch>` | Create a git worktree |
| `wt-attach <branch>` | Attach to an existing branch as worktree |
| `wt-ls` | List worktrees |
| `wt-rm <branch>` | Remove a worktree |

## How it works

1. Creates a temp directory under `/tmp` with devcontainer config
2. Starts a Docker container (`mcr.microsoft.com/devcontainers/base:ubuntu`)
3. Installs Claude Code, clones repos via SSH
4. Mounts `~/.ssh`, `~/.config/gh`, `~/.claude`, and `~/.gitconfig` from the host
5. On exit (shell close, Ctrl+C, or prompt completion), the container and temp directory are automatically removed
