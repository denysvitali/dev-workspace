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
