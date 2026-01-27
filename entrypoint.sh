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

# Always sync Nix profile from template to ensure Nix is available
# The template's profile includes the nix package with etc/profile.d/nix.sh
# This is needed because PVC-mounted profiles may not include Nix
NIX_PROFILE_SRC="$FRESH_HOME/.local/state/nix/profiles"
NIX_PROFILE_DST="$HOME/.local/state/nix/profiles"
if [ -d "$NIX_PROFILE_SRC" ]; then
    log "Syncing Nix profile from template to ensure Nix is available..."

    # Create destination directory if it doesn't exist
    mkdir -p "$NIX_PROFILE_DST"

    # Sync all profile links from template
    # We need to preserve existing user profiles but ensure at least one has Nix
    rsync -a --ignore-existing "$NIX_PROFILE_SRC/" "$NIX_PROFILE_DST/" 2>/dev/null || true

    # If the current profile doesn't have nix.sh, use the template's profile
    if [ ! -f "$NIX_PROFILE_DST/profile/etc/profile.d/nix.sh" ]; then
        TEMPLATE_PROFILE_LINK="$NIX_PROFILE_SRC/profile"
        if [ -L "$TEMPLATE_PROFILE_LINK" ]; then
            # Get what the template's profile points to
            TEMPLATE_TARGET=$(readlink "$TEMPLATE_PROFILE_LINK")
            if [ -e "$NIX_PROFILE_DST/$TEMPLATE_TARGET" ]; then
                # Update the current profile symlink to point to the template's profile
                ln -sf "$TEMPLATE_TARGET" "$NIX_PROFILE_DST/profile"
                log "Updated profile to use template's Nix-enabled profile"
            else
                # Copy the template's profile link target if it doesn't exist in PVC
                cp -a "$NIX_PROFILE_SRC/$TEMPLATE_TARGET" "$NIX_PROFILE_DST/"
                ln -sf "$TEMPLATE_TARGET" "$NIX_PROFILE_DST/profile"
                log "Copied template's Nix-enabled profile to PVC"
            fi
        fi
    fi

    log "Nix profile sync complete"
fi

# Initialize Nix store only if /nix is empty (first run on fresh PVC)
if [ -z "$(ls -A /nix 2>/dev/null)" ]; then
    log "Initializing Nix store (first run detected)..."
    # The image already has Nix installed, just need to ensure the store is usable
    # If /nix is empty but Nix is available in the image, this allows first channel setup
    mkdir -p /nix/var/nix/profiles/per-user/"$USER"
    log "Nix store initialized"
else
    log "Using existing Nix store from PVC"
fi

# Fix Nix profile symlink to point to the actual profile location
# Nix stores profiles in ~/.local/state/nix/profiles/ (modern single-user mode)
NIX_PROFILE_DIR="$HOME/.local/state/nix/profiles/profile"
if [ -L "$HOME/.nix-profile" ] || [ ! -e "$HOME/.nix-profile" ]; then
    log "Fixing Nix profile symlink..."
    rm -f "$HOME/.nix-profile"
    ln -s "$NIX_PROFILE_DIR" "$HOME/.nix-profile"
    log "Nix profile symlink fixed to $NIX_PROFILE_DIR"
fi

# Source Nix environment so nix/devenv commands are available
if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
    log "Nix environment loaded"
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
    export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
fi

log "Workspace container started successfully"
log "Running as user: $(whoami)"
log "Home directory: $HOME"

# Start Happy daemon if ANTHROPIC_API_KEY is set
if [ -n "$ANTHROPIC_API_KEY" ]; then
    log "Starting Happy daemon..."
    # Collect all ANTHROPIC_ and HAPPY_ environment variables
    DAEMON_ENVS=""
    for var in $(env | grep -E "^(ANTHROPIC_|HAPPY_)" | cut -d= -f1); do
        DAEMON_ENVS="$DAEMON_ENVS $var=${!var}"
    done
    # Start daemon in background, suppress errors if it fails (e.g., not authenticated)
    (env $DAEMON_ENVS happy daemon start 2>/dev/null || log "Happy daemon not started (may need authentication)") &
else
    log "ANTHROPIC_API_KEY not set, skipping Happy daemon"
fi

log "Accepting connections via SSH on port 2222..."

# Wait for dropbear to exit (or signal)
wait $DROPBEAR_PID
