# syntax=docker/dockerfile:1
FROM --platform=linux/arm64 debian:latest

# Install base system dependencies (including Swift runtime deps)
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo \
        curl \
        wget \
        git \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        libcurl4-openssl-dev \
        libxml2 \
        libedit2 \
        libsqlite3-0 \
        libc6-dev \
        binutils \
        libgcc-13-dev \
        libstdc++-13-dev \
        pkg-config \
        tzdata \
        unzip \
        bash \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user 'claude' with sudo privileges
RUN useradd -m -s /bin/bash -u 1000 claude \
    && echo 'claude ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/claude \
    && chmod 0440 /etc/sudoers.d/claude

# Install Node.js 24 via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install pnpm 10 globally
RUN npm install -g pnpm@10

# Install Docker CLI
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
       $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       | tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# Create docker group and add claude to it (GID is adjusted at runtime to match socket)
RUN groupadd -f docker && usermod -aG docker claude

# Create /workspace with correct ownership
RUN mkdir -p /workspace && chown claude:claude /workspace

# Entrypoint: lazily initialises home-dir tools (swiftly, Swift, Claude Code) on first
# run, since /home/claude is a volume mount that may start empty.
COPY --chmod=755 <<'EOF' /entrypoint.sh
#!/bin/bash
set -e

# Adjust docker group GID to match the mounted socket, if present
if [ -S /var/run/docker.sock ]; then
    SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
    CURRENT_GID=$(getent group docker | cut -d: -f3)
    if [ "$SOCK_GID" != "$CURRENT_GID" ] && [ "$SOCK_GID" != "0" ]; then
        sudo groupmod -g "$SOCK_GID" docker
    fi
fi

# Ensure volume-mounted user home is owned by claude
sudo chown -R claude:claude /home/claude 2>/dev/null || true

# ── Swiftly ────────────────────────────────────────────────────────────────────
SWIFTLY_HOME="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}"

if [ ! -x "$SWIFTLY_HOME/bin/swiftly" ]; then
    echo "==> Installing swiftly..."
    ARCH=$(uname -m)
    curl -fsSL "https://download.swift.org/swiftly/linux/swiftly-${ARCH}.tar.gz" \
        -o /tmp/swiftly.tar.gz
    tar -zxf /tmp/swiftly.tar.gz -C /tmp
    /tmp/swiftly init --quiet-shell-followup --assume-yes
    rm -f /tmp/swiftly /tmp/swiftly.tar.gz
fi

# Source swiftly environment so PATH is updated
[ -f "$SWIFTLY_HOME/env.sh" ] && . "$SWIFTLY_HOME/env.sh"

# Install latest stable Swift toolchain if none is active
if command -v swiftly &>/dev/null && ! swift --version &>/dev/null 2>&1; then
    echo "==> Installing Swift latest release..."
    swiftly install --assume-yes latest
fi

# ── Claude Code ────────────────────────────────────────────────────────────────
if [ ! -x "$HOME/.claude/bin/claude" ] && ! command -v claude &>/dev/null; then
    echo "==> Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
fi

# Extend PATH with all user-local bin directories
export PATH="$HOME/.claude/bin:$HOME/.local/bin:$SWIFTLY_HOME/bin:$PATH"

exec claude "$@"
EOF

VOLUME ["/home/claude", "/workspace"]

USER claude
WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
