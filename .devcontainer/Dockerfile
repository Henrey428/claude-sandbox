FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Pre-install Claude Code via the official native installer.
#
# Recent Claude Code releases ship a thin npm launcher plus a platform-native
# binary delivered as an *optional dependency* (downloaded by a postinstall).
# npm's optional-dependency download is unreliable inside Docker — when it
# fails, npm does NOT fail the install, so the launcher installs but the native
# binary is missing ("Error: claude native binary not installed"). The native
# installer fetches the correct binary directly and is the supported method.
#
# Install as the `vscode` user so the binary lands on that user's PATH at
# runtime (installer targets $HOME/.local/bin). The ADD pulls npm's "latest"
# metadata on every build; Docker only busts the cache when its content
# changes, so this RUN reinstalls only when a new version publishes. The
# `claude --version` smoke test fails the build loudly if the binary is
# missing, instead of producing a silently broken image.
ADD https://registry.npmjs.org/@anthropic-ai/claude-code/latest /tmp/claude-version.json
USER vscode
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && /home/vscode/.local/bin/claude --version
USER root
ENV PATH="/home/vscode/.local/bin:${PATH}"
