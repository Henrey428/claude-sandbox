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

echo "==> Fixing SSH key permissions..."
if [ -d "$HOME/.ssh" ]; then
  cp -r "$HOME/.ssh" "$HOME/.ssh-local"
  chmod 700 "$HOME/.ssh-local"
  chmod 600 "$HOME/.ssh-local"/* 2>/dev/null || true
  chmod 644 "$HOME/.ssh-local"/*.pub 2>/dev/null || true
  # Auto-detect SSH key: prefer ed25519, fall back to rsa
  SSH_KEY=""
  for key in id_ed25519 id_rsa; do
    if [ -f "$HOME/.ssh-local/$key" ]; then
      SSH_KEY="$HOME/.ssh-local/$key"
      break
    fi
  done
  if [ -n "$SSH_KEY" ]; then
    git config --global core.sshCommand "ssh -o StrictHostKeyChecking=accept-new -i $SSH_KEY"
  else
    echo "  ⚠ No SSH key found (looked for id_ed25519, id_rsa)"
  fi
fi

echo "==> Setting up GitHub CLI authentication..."
GH_TOKEN_FILE="$HOME/.config/gh-host/.gh-token"
if [ -f "$GH_TOKEN_FILE" ] && [ -s "$GH_TOKEN_FILE" ]; then
  GH_TOKEN_VALUE=$(cat "$GH_TOKEN_FILE")
  # Export GH_TOKEN so gh CLI and git credential helpers work everywhere
  echo "export GH_TOKEN='$GH_TOKEN_VALUE'" >> "$HOME/.bashrc"
  export GH_TOKEN="$GH_TOKEN_VALUE"
  # Verify the token works
  if gh auth status &>/dev/null; then
    echo "  ✓ GitHub CLI authenticated (token from host keychain)."
  else
    echo "  ⚠ Token found but gh auth status failed — token may be expired."
    echo "    Run 'gh auth login' on the host to refresh."
  fi
else
  echo "  ⚠ No GitHub token found. Run 'gh auth login' on the host first."
  echo "    (The host keychain token is extracted via initializeCommand.)"
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

# Always use --dangerously-skip-permissions inside the sandbox container
echo "alias claude='claude --dangerously-skip-permissions'" >> "$HOME/.bashrc"

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