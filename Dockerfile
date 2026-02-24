FROM ubuntu:24.04

# Enable universe repository for additional packages
RUN apt-get update && apt-get install -y software-properties-common && \
    add-apt-repository universe && \
    apt-get update

# Update and install system dependencies, core utilities, and development tools
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    curl \
    wget \
    git \
    git-doc \
    dropbear \
    mosh \
    openssh-client \
    sudo \
    vim \
    nano \
    htop \
    btop \
    net-tools \
    iputils-ping \
    bind9-dnsutils \
    jq \
    unzip \
    zip \
    ca-certificates \
    gnupg \
    bash \
    bash-completion \
    zsh \
    tmux \
    fzf \
    bat \
    eza \
    tree \
    less \
    findutils \
    grep \
    sed \
    tar \
    gzip \
    xz-utils \
    bzip2 \
    procps \
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
    golang-go \
    python3 \
    python3-pip \
    nodejs \
    npm \
    tzdata \
    ripgrep \
    fd-find \
    && rm -rf /var/lib/apt/lists/*

# Install yq (YAML processor) - download pre-built binary
RUN wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.35.2/yq_linux_amd64 && \
    chmod +x /usr/local/bin/yq

# Install NPM tools
RUN npm install -g pnpm yarn

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && apt-get install -y --no-install-recommends gh && rm -rf /var/lib/apt/lists/*

# Install kubectl
RUN curl -fsSL https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

# Set timezone and locale
ENV TZ=UTC
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Create workspace user and group (non-privileged)
# Ubuntu 24.04 has 'ubuntu' user with UID 1000 - rename it to 'workspace'
RUN usermod -l workspace ubuntu && \
    groupmod -n workspace ubuntu && \
    usermod -d /home/workspace -m workspace && \
    mkdir -p /workspace && chown -R workspace:workspace /workspace

# Install global npm packages (happy-coder)
RUN npm install -g happy-coder

USER workspace
# Install Claude Code
RUN curl -fsSL https://claude.ai/install.sh | bash
RUN /home/workspace/.local/bin/claude --version && /home/workspace/.local/bin/claude --ripgrep --version

USER root

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

# Install uv package manager (as workspace user)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
USER root

# Setup git configuration for workspace user
RUN git config --global init.defaultBranch main && \
    git config --global user.name "workspace" && \
    git config --global user.email "workspace@localhost" && \
    git config --global core.editor vim && \
    git config --global push.default simple && \
    git config --global pull.rebase false

# Create common directories for workspace user
RUN mkdir -p /home/workspace/go/src /home/workspace/go/bin /home/workspace/go/pkg /home/workspace/.local/bin /home/workspace/.config

# Move home contents to template location before /home is PVC-mounted at runtime
# entrypoint.sh will sync these contents to the PVC-mounted /home/workspace
USER root
RUN mkdir -p /home && \
    mv /home/workspace /home/template && \
    mkdir -p /home/workspace && \
    chown workspace:workspace /home/workspace && \
    chmod 750 /home/workspace

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
