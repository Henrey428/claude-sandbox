# claude-sandbox

Run Claude Code in a disposable devcontainer with full permissions. Clones one or more GitHub repos into an isolated Docker environment, then drops you into a shell (or runs Claude non-interactively).

Containers are automatically cleaned up on exit.

## Prerequisites

- Docker Desktop
- [devcontainer CLI](https://github.com/devcontainers/cli): `npm install -g @devcontainers/cli`

## Setup

```bash
git clone https://github.com/Henrey428/claude-sandbox.git
cd claude-sandbox
chmod +x claude-sandbox

# Add to PATH so you can run it from any repo
# (add to ~/.bashrc or ~/.zshrc)
export PATH="$PATH:$HOME/claude-sandbox"
```

### GitHub authentication

The sandbox uses a GitHub Personal Access Token (PAT) for all git and GitHub API operations. No SSH keys or host credentials are forwarded into the container.

1. Create a **classic** PAT at https://github.com/settings/tokens/new
   - Select the **`repo`** scope (covers clone, push, PRs, issues, etc.)
   - Set an expiration that works for you
2. Copy `.env.example` to `.env` and paste your token:

```bash
cp .env.example .env
# Edit .env and set your token:
# SANDBOX_GITHUB_TOKEN=ghp_...
```

The `.env` file is gitignored and never leaves your machine. The token is injected into the container as an environment variable at launch time.

> **Fine-grained vs classic PATs:** Fine-grained tokens can be scoped to specific repos, but are limited to a single organization. Classic tokens with `repo` scope work across all orgs and repos you have access to.

### Claude Code authentication

Claude Code credentials don't transfer from the macOS Keychain into the container automatically. On your first run, authenticate inside the container:

```bash
claude login
```

This saves credentials to `~/.claude/.credentials.json` on your host (via bind mount), so all future containers pick them up automatically.

## Usage

```
claude-sandbox [OPTIONS]                                    # auto-detect from current git repo
claude-sandbox --main org/repo[@branch] [OPTIONS]           # explicit main repo
```

### Options

| Flag | Description |
|------|-------------|
| `--main org/repo[@branch]` | Main repo. If omitted, auto-detects from current git directory. |
| `--branch <branch>` | Override branch for the main repo (useful with auto-detect). |
| `--repo org/repo[@branch]` | Additional repo. Repeat for multiple. |
| `--claude "prompt"` | Run Claude non-interactively with this prompt. |
| `--dir /path` | Override the temp project directory. |
| `-h, --help` | Show help. |

### Examples

```bash
# From inside any git repo — sandbox current repo on current branch
claude-sandbox

# Same repo, different branch
claude-sandbox --branch feature-x

# Current repo + an extra repo
claude-sandbox --repo myorg/shared-lib@feature-x

# Current repo, different branch, with Claude prompt
claude-sandbox --branch fix-auth \
  --claude "Fix the auth bug in issue #42"

# Explicit: specify everything
claude-sandbox \
  --main myorg/api-service@fix-auth \
  --repo myorg/shared-lib@v2-refactor \
  --repo myorg/infra-config@staging
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
2. Reads `SANDBOX_GITHUB_TOKEN` from `.env` and injects it into the container environment
3. Starts a Docker container (`mcr.microsoft.com/devcontainers/base:ubuntu`)
4. Installs Claude Code, configures git HTTPS credentials using the PAT, clones repos
5. Mounts `~/.gitconfig` and `~/.gnupg` read-only from the host; mounts `~/.claude` read-write so that `claude login` credentials persist across containers
6. On exit (shell close, Ctrl+C, or prompt completion), the container and temp directory are automatically removed

## Security

- **No SSH keys** are forwarded into the container. Authentication uses a GitHub PAT over HTTPS.
- The PAT is stored in `.env` (gitignored) and injected via `containerEnv` — it never touches the filesystem inside the container as a standalone file.
- `~/.gitconfig` and `~/.gnupg` are mounted **read-only**.
- `~/.claude` is mounted **read-write** so that credentials saved via `claude login` persist across container rebuilds. This means code running inside the sandbox can read and write to your host `~/.claude` directory. If this is a concern, you can switch the mount to read-only in `devcontainer.json` (you'll need to re-authenticate on every launch).
