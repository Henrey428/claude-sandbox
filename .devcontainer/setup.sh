#!/usr/bin/env bash
set -euo pipefail

echo "==> Checking Claude Code..."
if command -v claude &> /dev/null; then
  echo "  ✓ Claude Code already installed ($(claude --version 2>/dev/null || echo 'cached'))"
else
  echo "  Installing Claude Code..."
  npm install -g @anthropic-ai/claude-code
fi

echo "==> Making gitconfig writable..."
if [ -f "$HOME/.gitconfig-host" ]; then
  cp "$HOME/.gitconfig-host" "$HOME/.gitconfig-local"
fi

# Disable GPG commit signing inside the container (unreliable without a TTY)
git config --file "$HOME/.gitconfig-local" commit.gpgsign false
git config --file "$HOME/.gitconfig-local" tag.gpgsign false

echo "==> Setting up GitHub authentication..."
# SANDBOX_GITHUB_TOKEN is injected into containerEnv by the launcher
GH_TOKEN_VALUE="${SANDBOX_GITHUB_TOKEN:-}"

if [ -n "$GH_TOKEN_VALUE" ]; then
  # Export for gh CLI
  echo "export GH_TOKEN='$GH_TOKEN_VALUE'" >> "$HOME/.bashrc"
  export GH_TOKEN="$GH_TOKEN_VALUE"

  # Configure git to use the token for HTTPS access to github.com
  # This replaces SSH key auth — no private keys inside the container
  # Write the token value directly into the helper (not an env var reference)
  # so it works reliably in all contexts (postCreateCommand, interactive shell, etc.)
  git config --file "$HOME/.gitconfig-local" \
    credential.https://github.com.helper \
    "!f() { echo username=x-access-token; echo password=$GH_TOKEN_VALUE; }; f"

  # Verify the token works
  if gh auth status &>/dev/null; then
    echo "  ✓ GitHub authenticated (token)."
  else
    echo "  ⚠ Token found but gh auth status failed — token may be expired."
    echo "    Check SANDBOX_GITHUB_TOKEN in your .env file."
  fi
else
  echo "  ⚠ No GitHub token found. Set SANDBOX_GITHUB_TOKEN in your .env file."
fi

# TODO: GPG signing is currently broken inside the container (no TTY for pinentry,
#       gpg-preset-passphrase not always available). Signing is disabled via gitconfig
#       above. Fix or remove this section once resolved.
echo "==> Setting up GPG key signing..."
if [ -d "$HOME/.gnupg-host" ]; then
  # Create a clean writable .gnupg with only the essential files
  mkdir -p "$HOME/.gnupg/private-keys-v1.d"
  chmod 700 "$HOME/.gnupg" "$HOME/.gnupg/private-keys-v1.d"

  # Copy keyrings and private keys (skip lock files, sockets, agent state)
  for f in pubring.kbx trustdb.gpg gpg.conf; do
    [ -f "$HOME/.gnupg-host/$f" ] && cp "$HOME/.gnupg-host/$f" "$HOME/.gnupg/$f"
  done
  if [ -d "$HOME/.gnupg-host/private-keys-v1.d" ]; then
    cp "$HOME/.gnupg-host/private-keys-v1.d/"*.key "$HOME/.gnupg/private-keys-v1.d/" 2>/dev/null || true
    chmod 600 "$HOME/.gnupg/private-keys-v1.d/"*.key 2>/dev/null || true
  fi

  # Configure gpg-agent for non-interactive signing
  cat > "$HOME/.gnupg/gpg-agent.conf" << 'GPGAGENT'
default-cache-ttl 86400
max-cache-ttl 604800
allow-preset-passphrase
allow-loopback-pinentry
GPGAGENT

  # Restart agent to pick up new config
  gpgconf --kill gpg-agent 2>/dev/null || true

  # Add helper to unlock GPG key once per session (caches passphrase in agent)
  cat >> "$HOME/.bashrc" << 'GPGHELPER'
export GPG_TTY=$(tty)
gpg-unlock() {
  local keygrip
  keygrip=$(gpg --list-secret-keys --with-keygrip 2>/dev/null | awk '/^sec/{found=1} found && /Keygrip/{print $3; exit}')
  if [ -z "$keygrip" ]; then
    echo "No GPG secret key found."
    return 1
  fi
  read -s -p "GPG passphrase: " passphrase
  echo
  if echo "$passphrase" | /usr/lib/gnupg/gpg-preset-passphrase --preset "$keygrip" 2>/dev/null; then
    echo "GPG key unlocked — signing will work without a TTY."
  else
    echo "Failed to preset passphrase. Try: gpgconf --kill gpg-agent && gpg-unlock"
  fi
}
GPGHELPER

  # Verify key is available
  if gpg --list-secret-keys --keyid-format long 2>/dev/null | grep -q "sec"; then
    echo "  ✓ GPG signing keys imported."
    echo "    Run 'gpg-unlock' once to cache your passphrase for the session."
  else
    echo "  ⚠ GPG keys copied but no secret keys detected."
  fi
else
  echo "  ⚠ No GPG keys found. Mount ~/.gnupg to enable commit signing."
fi

echo "==> Setting up workspace helpers..."
cat >> "$HOME/.bashrc" << 'HELPERS'

# Resolve the actual workspace dir (the mounted devcontainer folder)
WORKSPACE_ROOT="$(ls -d /workspaces/*/ 2>/dev/null | head -1)"
WORKSPACE_ROOT="${WORKSPACE_ROOT%/}"
export WORKSPACE_ROOT

# Instance name for prompt/title identification
SANDBOX_INSTANCE="$(basename "$WORKSPACE_ROOT" 2>/dev/null)"
export SANDBOX_INSTANCE

# ─── Worktree helpers ───
wt-add() {
  local branch="${1:?Usage: wt-add <branch> [start-point]}"
  local start="${2:-HEAD}"
  local dir="../worktrees/${branch}"
  git worktree add -b "$branch" "$dir" "$start"
  echo "Worktree created at $dir"
  cd "$dir"
}

wt-attach() {
  local branch="${1:?Usage: wt-attach <branch>}"
  local dir="../worktrees/${branch}"
  git worktree add "$dir" "$branch"
  echo "Worktree attached at $dir"
  cd "$dir"
}

alias wt-ls='git worktree list'

wt-rm() {
  local branch="${1:?Usage: wt-rm <branch>}"
  git worktree remove "../worktrees/${branch}"
  echo "Worktree removed: $branch"
}

# ─── Multi-repo helpers ───

# Show current workspace layout
ws-status() {
  echo "=== Workspace: $WORKSPACE_ROOT ==="
  echo ""
  for repo in "$WORKSPACE_ROOT"/repos/*/; do
    [ -d "$repo/.git" ] || continue
    local name=$(basename "$repo")
    local branch=$(git -C "$repo" branch --show-current 2>/dev/null || echo "detached")
    local main_marker=""
    [ -L "$WORKSPACE_ROOT/main" ] && [ "$(readlink -f "$WORKSPACE_ROOT/main")" = "$(readlink -f "$repo")" ] && main_marker=" ★ main"
    echo "  📦 $name ($branch)$main_marker"
    # Show worktrees if any
    local wt_dir="$WORKSPACE_ROOT/repos/${name}-worktrees"
    if [ -d "$wt_dir" ]; then
      for wt in "$wt_dir"/*/; do
        [ -d "$wt" ] || continue
        local wt_branch=$(git -C "$wt" branch --show-current 2>/dev/null || echo "detached")
        echo "     └─ worktree: $(basename "$wt") ($wt_branch)"
      done
    fi
  done
}

# Jump to a repo: ws-cd <repo-name>
ws-cd() {
  local name="${1:?Usage: ws-cd <repo-name>}"
  local target="$WORKSPACE_ROOT/repos/$name"
  if [ ! -d "$target" ]; then
    echo "Repo '$name' not found. Available:"
    ls "$WORKSPACE_ROOT/repos/" 2>/dev/null
    return 1
  fi
  cd "$target"
  echo "→ $name ($(git branch --show-current 2>/dev/null))"
}

# Jump to main repo
ws-main() {
  if [ -L "$WORKSPACE_ROOT/main" ]; then
    cd "$(readlink -f "$WORKSPACE_ROOT/main")"
    echo "→ main repo: $(basename "$(pwd)") ($(git branch --show-current 2>/dev/null))"
  else
    echo "No main repo set. Use the launcher with --main."
  fi
}

HELPERS

echo "==> Configuring terminal prompt with instance name..."
# Ensure login shells source .bashrc through the standard profile chain.
# bash --login reads ~/.bash_profile first; without it, ~/.profile is used.
# Creating .bash_profile that sources .profile preserves the default Ubuntu
# chain (.profile → .bashrc) and ensures our .bashrc additions always run.
if [ ! -f "$HOME/.bash_profile" ]; then
    echo '[ -f "$HOME/.profile" ] && . "$HOME/.profile"' > "$HOME/.bash_profile"
fi

# Use a PROMPT_COMMAND function instead of a one-shot PS1 assignment.
# This runs AFTER the devcontainer theme's prompt function, so the instance
# tag survives even if something resets PS1 between prompts.
# The claude wrapper restores the title immediately after Claude Code exits
# (Claude Code overwrites the terminal title while it runs).
cat >> "$HOME/.bashrc" << 'PROMPT_PATCH'

# ─── Instance name in prompt and terminal title ───
__sandbox_set_title() {
    case "$TERM" in xterm*)
        printf '\033]0;[%s] %s: %s\007' "${SANDBOX_INSTANCE:-sandbox}" "${USER}" "${PWD}"
    ;; esac
}

__sandbox_prompt() {
    local tag="[${SANDBOX_INSTANCE:-sandbox}]"
    # Prepend instance tag to PS1 (idempotent — skips if already tagged)
    if [[ "$PS1" != *"$tag"* ]]; then
        PS1="\[\033[1;36m\]${tag}\[\033[0m\] ${PS1}"
    fi
    __sandbox_set_title
}
# Append so it runs after any theme prompt functions in PROMPT_COMMAND
PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND}; }__sandbox_prompt"

# Wrap claude to always use --dangerously-skip-permissions inside the sandbox
# and restore the terminal title immediately after Claude Code exits
claude() {
    command claude --dangerously-skip-permissions "$@"
    local rc=$?
    __sandbox_set_title
    return $rc
}
PROMPT_PATCH

# Patch the zsh prompt to include instance name
cat >> "$HOME/.zshrc" << 'ZSH_PATCH'

# Instance name for prompt/title identification
WORKSPACE_ROOT="$(ls -d /workspaces/*/ 2>/dev/null | head -1)"
WORKSPACE_ROOT="${WORKSPACE_ROOT%/}"
export WORKSPACE_ROOT
SANDBOX_INSTANCE="$(basename "$WORKSPACE_ROOT" 2>/dev/null)"
export SANDBOX_INSTANCE

# Prepend instance name to the prompt
PROMPT="%{$fg_bold[cyan]%}[${SANDBOX_INSTANCE:-sandbox}]%{$reset_color%} ${PROMPT}"

# Set terminal title to include instance name
precmd() {
  print -Pn "\e]0;[${SANDBOX_INSTANCE:-sandbox}] %n: %~\a"
}
preexec() {
  print -Pn "\e]0;[${SANDBOX_INSTANCE:-sandbox}] %n: $1\a"
}
ZSH_PATCH

echo "==> Auto-trusting workspace directories for Claude Code..."
CLAUDE_JSON="$HOME/.claude/.claude.json"
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
if [ -f "$CLAUDE_JSON" ]; then
  # 1) Purge stale /workspaces/* entries left by previous containers
  removed=$(python3 -c "
import json, sys
f = '$CLAUDE_JSON'
d = json.load(open(f))
projects = d.get('projects', {})
stale = [k for k in projects if k.startswith('/workspaces/')]
for k in stale:
    del projects[k]
if stale:
    json.dump(d, open(f, 'w'), indent=2)
print(len(stale))
")
  [ "$removed" -gt 0 ] 2>/dev/null && echo "  ✓ Cleaned $removed stale container trust entries"

  # Also remove stale project data directories (-workspaces-*)
  if [ -d "$CLAUDE_PROJECTS_DIR" ]; then
    for stale_dir in "$CLAUDE_PROJECTS_DIR"/-workspaces-*/; do
      [ -d "$stale_dir" ] || continue
      rm -rf "$stale_dir"
    done
  fi

  # 2) Trust all workspace directories in the current container
  python3 -c "
import json, glob, os
f = '$CLAUDE_JSON'
d = json.load(open(f))
projects = d.setdefault('projects', {})
trust = {'allowedTools': [], 'hasTrustDialogAccepted': True, 'hasCompletedProjectOnboarding': True}

dirs = set()
# Multi-repo layout: /workspaces/*/repos/*/
for p in glob.glob('/workspaces/*/repos/*/'):
    if os.path.isdir(p):
        dirs.add(p.rstrip('/'))
# Single-repo / workspace root: /workspaces/*/
for p in glob.glob('/workspaces/*/'):
    if os.path.isdir(p):
        dirs.add(p.rstrip('/'))

added = []
for d_path in sorted(dirs):
    if d_path not in projects:
        projects[d_path] = dict(trust)
        added.append(d_path)

if added:
    json.dump(d, open(f, 'w'), indent=2)
    for a in added:
        print(f'  ✓ Trusted: {a}')
else:
    print('  ✓ All workspace directories already trusted')
"
else
  echo "  ⚠ Claude config not found — trust will be prompted on first run."
fi

echo "==> Checking Claude Code authentication..."
if [ -f "$HOME/.claude/.credentials.json" ]; then
  echo "  ✓ Credentials found — already authenticated."
else
  echo ""
  echo "  ⚠ No credentials found. Run 'claude login' once to authenticate."
  echo "    Your login will persist across container rebuilds."
  echo ""
fi

echo "==> Setup complete."