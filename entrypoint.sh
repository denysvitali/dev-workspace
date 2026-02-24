#!/bin/bash

set -e

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to handle errors
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Signal handler for graceful shutdown
cleanup() {
    log "Received shutdown signal, cleaning up..."
    # Kill dropbear if running
    if [ -n "$DROPBEAR_PID" ]; then
        kill "$DROPBEAR_PID" 2>/dev/null || true
    fi
    log "Container shutting down gracefully"
    exit 0
}

trap cleanup SIGTERM SIGINT

log "Starting workspace container as user: $(whoami)"

# Sync fresh image home contents to PVC-mounted /home
# The original home contents were moved to /home/template during build
# Skip .gitconfig as users may have custom configurations
log "Syncing home directory contents from image to PVC..."
FRESH_HOME="/home/template"

# Sync fresh contents to PVC-mounted /home, preserving existing user files
if [ -d "$FRESH_HOME" ] && [ -n "$(ls -A "$FRESH_HOME" 2>/dev/null)" ]; then
    log "Syncing fresh home contents to PVC mount..."

    # Preserve SSH directory if it exists (user keys are already there or will be configured)
    if [ -d "$HOME/.ssh" ]; then
        mkdir -p "$FRESH_HOME/.ssh"
        cp -a "$HOME/.ssh/." "$FRESH_HOME/.ssh/" 2>/dev/null || true
    fi

    # Use rsync to sync fresh contents, skipping .gitconfig and preserving existing files
    # --ignore-existing preserves user-created/modified files
    # Exclude .gitconfig as requested
    rsync -a --ignore-existing --exclude='.gitconfig' "$FRESH_HOME/" "$HOME/" 2>/dev/null || {
        # Fallback if rsync fails (e.g., first deployment with empty PVC)
        cp -a "$FRESH_HOME/." "$HOME/" 2>/dev/null || true
    }

    # Ensure .ssh directory has correct permissions
    if [ -d "$HOME/.ssh" ]; then
        chmod 700 "$HOME/.ssh"
        chmod 600 "$HOME/.ssh/authorized_keys" 2>/dev/null || true
    fi

    log "Home directory sync complete"
fi

# Setup Nix - install if not present (first run), otherwise use existing from PVC
NIX_PROFILE_DIR="$HOME/.local/state/nix/profiles/profile"
NIX_INITIALIZED=0

if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    log "Nix already installed, loading environment..."
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
    log "Nix environment loaded from existing installation"
else
    log "Installing Nix package manager (first run detected)..."

    # Create nix directory and set ownership
    mkdir -p /nix
    chown workspace:workspace /nix

    # Install Nix (single-user mode, no daemon)
    su - "$USER" -c "curl -L https://nixos.org/nix/install | sh -s -- --no-daemon" || error_exit "Nix installation failed"

    # Configure Nix with flakes
    mkdir -p "$HOME/.config/nix"
    echo "experimental-features = nix-command flakes" >> "$HOME/.config/nix/nix.conf"

    # Add Nix to shell configs
    echo '. ~/.nix-profile/etc/profile.d/nix.sh' >> "$HOME/.bashrc"
    echo '. ~/.nix-profile/etc/profile.d/nix.sh' >> "$HOME/.profile"

    # Source Nix
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"

    # Install devenv via nix
    log "Installing devenv via Nix..."
    nix profile install nixpkgs#devenv || error_exit "Failed to install devenv"

    NIX_INITIALIZED=1
    log "Nix and devenv installed successfully"
fi

# Ensure .nix-profile symlink exists (may not persist across restarts)
if [ ! -L "$HOME/.nix-profile" ]; then
    mkdir -p "$HOME/.local/state/nix/profiles"
    ln -s "$NIX_PROFILE_DIR" "$HOME/.nix-profile"
fi

# Source Nix environment if available
if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi

# Generate SSH host keys if they don't exist
# Keys may already exist if /etc/dropbear is mounted from a PVC
KEYS_GENERATED=0
if [ ! -f /etc/dropbear/dropbear_rsa_host_key ]; then
    log "Generating RSA host key..."
    dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null
    KEYS_GENERATED=1
fi
if [ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]; then
    log "Generating ECDSA host key..."
    dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key 2>/dev/null
    KEYS_GENERATED=1
fi
if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ]; then
    log "Generating Ed25519 host key..."
    dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null
    KEYS_GENERATED=1
fi
if [ $KEYS_GENERATED -eq 0 ]; then
    log "Using existing SSH host keys from volume"
else
    log "SSH host keys ready"
fi

# Setup SSH keys if provided
if [ -n "$SSH_PUBLIC_KEY" ]; then
    log "Setting up SSH public key..."

    # Validate SSH key format
    if ! echo "$SSH_PUBLIC_KEY" | grep -qE "^(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-)"; then
        error_exit "Invalid SSH public key format"
    fi

    # Create .ssh directory if it doesn't exist (should already exist from Dockerfile)
    mkdir -p "$HOME/.ssh"
    echo "$SSH_PUBLIC_KEY" > "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
    chmod 700 "$HOME/.ssh"
    log "SSH public key configured"
fi

# Start dropbear SSH daemon on port 2222 (non-privileged port)
# -F: Don't fork (foreground mode for signal handling)
# -E: Log to stderr instead of syslog
# -p: Port to listen on
# -r: Host key files
# -s: Disable password logins
# -g: Disable password logins for root
log "Starting dropbear SSH daemon on port 2222..."
dropbear -F -E -p 2222 \
    -r /etc/dropbear/dropbear_rsa_host_key \
    -r /etc/dropbear/dropbear_ecdsa_host_key \
    -r /etc/dropbear/dropbear_ed25519_host_key \
    -s -g &
DROPBEAR_PID=$!

# Set workspace name if provided (just for display, can't change hostname without root)
if [ -n "$WORKSPACE_NAME" ]; then
    log "Workspace name: $WORKSPACE_NAME"
fi

# Initialize Claude Code if API key is provided
if [ -n "$ANTHROPIC_API_KEY" ]; then
    log "Claude Code API key provided, setting up..."
fi

log "Workspace container started successfully"
log "Running as user: $(whoami)"
log "Home directory: $HOME"

# Run user startup script if present
if [ -f "$HOME/start.sh" ]; then
    log "Running user startup script $HOME/start.sh..."
    bash "$HOME/start.sh" || log "Warning: start.sh exited with error $?"
fi

log "Accepting connections via SSH on port 2222..."

# Wait for dropbear to exit (or signal)
wait $DROPBEAR_PID
