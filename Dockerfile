FROM alpine:latest

# Update and install system dependencies, core utilities, and development tools
RUN apk update && apk upgrade && apk add --no-cache \
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

# Create workspace directory
RUN mkdir -p /workspace

# Create workspace user and group (non-privileged)
RUN addgroup workspace && \
    adduser -D -s /bin/bash -G workspace workspace && \
    chown workspace:workspace /workspace

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
ENV RUSTUP_HOME="/home/workspace/.rustup"
ENV CARGO_HOME="/home/workspace/.cargo"

# Install Rust via rustup for workspace user
USER workspace
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable && \
    . /home/workspace/.cargo/env && \
    rustup component add rustfmt clippy
USER root

# Install Nix package manager (multi-user installation)
RUN mkdir -p /nix && chown root:root /nix && \
    # Create nixbld group and users for multi-user Nix
    addgroup -g 30000 nixbld && \
    for i in $(seq 1 10); do \
        adduser -S -D -H -h /var/empty -g "Nix build user $i" -s /sbin/nologin -G nixbld -u $((30000 + i)) nixbld$i; \
    done && \
    # Add workspace user to nix-users group for access
    addgroup nix-users && \
    adduser workspace nix-users

# Install Nix using the official installer
RUN curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes && \
    # Source nix profile and configure for multi-user
    . /etc/profile.d/nix.sh && \
    # Create nix.conf with flakes and nix-command enabled
    mkdir -p /etc/nix && \
    echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf && \
    echo "trusted-users = root workspace" >> /etc/nix/nix.conf && \
    echo "allowed-users = *" >> /etc/nix/nix.conf

# Add Nix to PATH for all users
ENV PATH="/nix/var/nix/profiles/default/bin:$PATH"

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
        # Check if workspace user shell is accessible \
        su - workspace -c "whoami" > /dev/null || exit 1; \
        echo "All services healthy" \
    '

ENTRYPOINT ["/entrypoint.sh"]