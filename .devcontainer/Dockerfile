FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Pre-install Claude Code (cached in Docker layer)
RUN npm install -g @anthropic-ai/claude-code
