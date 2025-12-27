FROM alpine:latest

# Update and install system dependencies, core utilities, and development tools
RUN apk update && apk upgrade && apk add --no-cache \
    curl \
    wget \
    git \
    git-doc \
    dropbear \
    dropbear-dbclient \
    mosh \
    openssh-client \
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
    kubectl \
    tzdata \
    pnpm \
    github-cli \
    libgudev-dev \
    gcompat \
    libc6-compat \
    && rm -rf /var/cache/apk/*

# Set timezone and locale
ENV TZ=UTC
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Install global npm packages (happy-coder and claude-code)
RUN npm install -g happy-coder @anthropic-ai/claude-code

# Create workspace user and group (non-privileged)
# Manually create group and user to avoid busybox useradd issues
RUN echo "workspace:x:1000:" >> /etc/group
RUN echo "workspace:x:1000:1000:workspace:/home/workspace:/bin/bash" >> /etc/passwd
RUN mkdir -p /home/workspace && chown 1000:1000 /home/workspace
RUN chown -R 1000:1000 /workspace

# Setup dropbear SSH
# Create directory for host keys (will be generated at runtime or mounted as volume)
RUN mkdir -p /etc/dropbear && \
    chown workspace:workspace /etc/dropbear
# NOTE: Host keys are generated at runtime in entrypoint.sh for security
# Each container instance gets unique keys unless a volume is mounted

# Setup SSH directory for workspace user
RUN mkdir -p /home/workspace/.ssh && \
    chmod 700 /home/workspace/.ssh && \
    chown workspace:workspace /home/workspace/.ssh

# Create startup script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Copy BOM generation script
COPY scripts/generate-bom.sh /usr/local/bin/generate-bom
RUN chmod +x /usr/local/bin/generate-bom

# Set working directory
WORKDIR /workspace

# Setup environment variables
ENV PATH="/home/workspace/.cargo/bin:/home/workspace/.local/bin:$PATH"
ENV GOPATH="/home/workspace/go"
ENV EDITOR=vim
ENV PAGER=less
ENV RUSTUP_HOME="/home/workspace/.rustup"
ENV CARGO_HOME="/home/workspace/.cargo"

# Install Rust via rustup for workspace user
USER workspace
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable && \
    . /home/workspace/.cargo/env && \
    rustup component add rustfmt clippy
USER root

# Install Nix package manager (single-user installation for non-root operation)
RUN mkdir -p /nix && chown workspace:workspace /nix

# Install Nix as workspace user (single-user mode - no daemon required)
USER workspace
RUN curl -L https://nixos.org/nix/install | sh -s -- --no-daemon && \
    # Configure Nix with flakes enabled
    mkdir -p ~/.config/nix && \
    echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

# Add Nix to PATH for workspace user
ENV PATH="/home/workspace/.nix-profile/bin:$PATH"

# Install devenv via nix profile
RUN . ~/.nix-profile/etc/profile.d/nix.sh && \
    nix profile install nixpkgs#devenv

# Setup shell configuration with useful aliases for workspace user
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
    echo 'source /usr/share/bash-completion/bash_completion' >> ~/.bashrc && \
    # Source Nix environment in bashrc \
    echo '. ~/.nix-profile/etc/profile.d/nix.sh' >> ~/.bashrc && \
    # Also add to .profile for login shells (SSH) \
    echo '. ~/.nix-profile/etc/profile.d/nix.sh' >> ~/.profile

# Setup git configuration for workspace user
RUN git config --global init.defaultBranch main && \
    git config --global user.name "workspace" && \
    git config --global user.email "workspace@localhost" && \
    git config --global core.editor vim && \
    git config --global push.default simple && \
    git config --global pull.rebase false

# Create common directories for workspace user
RUN mkdir -p ~/go/src ~/go/bin ~/go/pkg ~/.local/bin ~/.config

# Move home contents to template location before /home is PVC-mounted at runtime
# entrypoint.sh will sync these contents to the PVC-mounted /home/workspace
USER root
RUN mkdir -p /home && \
    mv /home/workspace /home/template && \
    mkdir -p /home/workspace && \
    chown workspace:workspace /home/workspace && \
    chmod 750 /home/workspace
USER workspace

# Expose SSH (high port for non-root) and Mosh ports
EXPOSE 2222
EXPOSE 60000-61000/udp

# Add comprehensive health check
HEALTHCHECK --interval=30s --timeout=15s --start-period=10s --retries=3 \
    CMD bash -c ' \
        # Check if dropbear SSH daemon is running \
        pgrep dropbear > /dev/null || exit 1; \
        # Check if workspace user shell is accessible \
        whoami > /dev/null || exit 1; \
        echo "All services healthy" \
    '

# Already running as workspace user from Nix installation
ENTRYPOINT ["/entrypoint.sh"]