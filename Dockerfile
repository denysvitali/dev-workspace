FROM alpine:latest

# Install system dependencies, core utilities, and development tools
RUN apk add --no-cache \
    curl \
    wget \
    git \
    git-doc \
    openssh \
    openssh-client \
    mosh \
    sudo \
    vim \
    nano \
    htop \
    btop \
    net-tools \
    iputils \
    bind-tools \
    jq \
    yq \
    unzip \
    zip \
    ca-certificates \
    gnupg \
    bash \
    bash-completion \
    zsh \
    zsh-autosuggestions \
    zsh-syntax-highlighting \
    build-base \
    musl-dev \
    linux-headers \
    tmux \
    ripgrep \
    fd \
    fzf \
    bat \
    exa \
    tree \
    less \
    findutils \
    grep \
    sed \
    tar \
    gzip \
    xz \
    bzip2 \
    procps \
    shadow \
    util-linux \
    coreutils \
    diffutils \
    file \
    lsof \
    strace \
    tcpdump \
    nmap \
    rsync \
    screen \
    go \
    python3 \
    py3-pip \
    python3-dev \
    nodejs \
    npm \
    yarn \
    tailscale \
    kubectl \
    tzdata \
    pnpm \
    github-cli \
    libgudev-dev \
    && rm -rf /var/cache/apk/*

# Set timezone and locale
ENV TZ=UTC
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Install global npm packages
RUN npm install -g @anthropic-ai/claude-code

# Install Rust (using official rustup script for latest version)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable && \
    . ~/.cargo/env

# Create workspace directory
RUN mkdir -p /workspace

# Create workspace user and group (non-privileged)
RUN addgroup workspace && \
    adduser -D -s /bin/bash -G workspace workspace && \
    chown workspace:workspace /workspace

# Create tailscale group and configure for root access when needed
RUN addgroup tailscale && \
    echo '%tailscale ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# Setup SSH
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Create startup script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set working directory
WORKDIR /workspace

# Setup environment variables
ENV PATH="/home/workspace/.cargo/bin:/home/workspace/.local/bin:$PATH"
ENV GOPATH="/home/workspace/go"
ENV EDITOR=vim
ENV PAGER=less

# Initialize Rust environment for workspace user
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable

# Setup shell configuration with useful aliases
RUN echo 'alias ll="exa -la"' >> ~/.bashrc && \
    echo 'alias la="exa -la"' >> ~/.bashrc && \
    echo 'alias lt="exa --tree"' >> ~/.bashrc && \
    echo 'alias cat="bat"' >> ~/.bashrc && \
    echo 'alias find="fd"' >> ~/.bashrc && \
    echo 'alias grep="rg"' >> ~/.bashrc && \
    echo 'alias top="btop"' >> ~/.bashrc && \
    echo 'alias ..="cd .."' >> ~/.bashrc && \
    echo 'alias ...="cd ../.."' >> ~/.bashrc && \
    echo 'alias gs="git status"' >> ~/.bashrc && \
    echo 'alias gl="git log --oneline"' >> ~/.bashrc && \
    echo 'alias gd="git diff"' >> ~/.bashrc && \
    echo 'alias gb="git branch"' >> ~/.bashrc && \
    echo 'export FZF_DEFAULT_COMMAND="fd --type f"' >> ~/.bashrc && \
    echo 'export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"' >> ~/.bashrc && \
    echo 'source /usr/share/bash-completion/bash_completion' >> ~/.bashrc

# Setup git configuration
RUN git config --global init.defaultBranch main && \
    git config --global user.name "workspace" && \
    git config --global user.email "workspace@localhost" && \
    git config --global core.editor vim && \
    git config --global push.default simple && \
    git config --global pull.rebase false

# Create common directories
RUN mkdir -p ~/go/src ~/go/bin ~/go/pkg ~/.local/bin ~/.ssh ~/.config

# Expose SSH and Mosh ports
EXPOSE 22
EXPOSE 60000-61000/udp

# Add comprehensive health check
HEALTHCHECK --interval=30s --timeout=15s --start-period=10s --retries=3 \
    CMD bash -c ' \
        # Check if SSH daemon is running \
        pgrep sshd > /dev/null || exit 1; \
        # Check if Tailscale daemon is running (if configured) \
        if [ -n "$TAILSCALE_AUTH_KEY" ]; then \
            pgrep tailscaled > /dev/null || exit 1; \
            # Check if Tailscale is connected \
            tailscale status > /dev/null 2>&1 || exit 1; \
        fi; \
        # Check if workspace user shell is accessible \
        su - workspace -c "whoami" > /dev/null || exit 1; \
        echo "All services healthy" \
    '

ENTRYPOINT ["/entrypoint.sh"]