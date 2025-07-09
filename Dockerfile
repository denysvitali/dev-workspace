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
    && rm -rf /var/cache/apk/*

# Set timezone and locale
ENV TZ=UTC
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable && \
    . ~/.cargo/env

# Create workspace user
RUN adduser -D -s /bin/bash -G wheel workspace && \
    echo 'workspace ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers && \
    chown workspace:workspace /workspace

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Setup SSH
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Create workspace directory
RUN mkdir -p /workspace

# Create startup script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Switch to workspace user
USER workspace
WORKDIR /workspace

# Setup environment variables
ENV PATH="/home/workspace/.cargo/bin:/home/workspace/.local/bin:$PATH"
ENV GOPATH="/home/workspace/go"
ENV EDITOR=vim
ENV PAGER=less

# Initialize Rust environment for workspace user
RUN . ~/.cargo/env

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

# Add health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD pgrep -f "sshd|tailscaled" > /dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]