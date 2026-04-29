FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Pre-install Claude Code. The ADD above pulls npm's "latest" metadata on every
# build; Docker only busts the cache when its content changes, so this RUN
# reinstalls only when a new version of @anthropic-ai/claude-code is published.
ADD https://registry.npmjs.org/@anthropic-ai/claude-code/latest /tmp/claude-version.json
RUN npm install -g @anthropic-ai/claude-code
