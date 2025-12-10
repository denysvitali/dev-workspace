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

# Function to retry commands
retry() {
    local retries=$1
    shift
    local count=0

    until "$@"; do
        exit_code=$?
        count=$((count + 1))
        if [ $count -lt $retries ]; then
            log "Command failed (attempt $count/$retries). Retrying in 5 seconds..."
            sleep 5
        else
            error_exit "Command failed after $retries attempts: $*"
        fi
    done
}

# Signal handler for graceful shutdown
cleanup() {
    log "Received shutdown signal, cleaning up..."
    log "Container shutting down gracefully"
    exit 0
}

trap cleanup SIGTERM SIGINT

log "Starting workspace container..."

# Generate SSH host keys if they don't exist
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    log "Generating SSH host keys..."
    ssh-keygen -A
fi

# Start sshd daemon in the background
/usr/sbin/sshd -D &

# Start Nix daemon if available
if [ -x /nix/var/nix/profiles/default/bin/nix-daemon ]; then
    log "Starting Nix daemon..."
    /nix/var/nix/profiles/default/bin/nix-daemon &
fi

# Setup SSH keys if provided
if [ -n "$SSH_PUBLIC_KEY" ]; then
    log "Setting up SSH public key..."

    # Validate SSH key format
    if ! echo "$SSH_PUBLIC_KEY" | grep -qE "^(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-)"; then
        error_exit "Invalid SSH public key format"
    fi

    mkdir -p /home/workspace/.ssh
    echo "$SSH_PUBLIC_KEY" > /home/workspace/.ssh/authorized_keys
    chmod 600 /home/workspace/.ssh/authorized_keys
    chmod 700 /home/workspace/.ssh
    chown -R workspace:workspace /home/workspace/.ssh
    log "SSH public key configured"
fi

# Set workspace name if provided
if [ -n "$WORKSPACE_NAME" ]; then
    log "Setting workspace name to: $WORKSPACE_NAME"
    hostnamectl set-hostname "$WORKSPACE_NAME" 2>/dev/null || true
fi

# Initialize Claude Code if API key is provided
if [ -n "$ANTHROPIC_API_KEY" ]; then
    log "Claude Code API key provided, setting up..."
    export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
    # Claude Code will use the API key from environment variable
fi

log "Workspace container started successfully"
log "Container hostname: $(hostname)"
log "Container IP addresses:"
ip addr show | grep -E 'inet.*scope global' | awk '{print "  " $2}' || true

# Collect ANTHROPIC_ environment variables to pass to happy daemon
ANTHROPIC_ENVS=""
for var in $(env | grep -E "^ANTHROPIC_" | cut -d= -f1); do
    ANTHROPIC_ENVS="$ANTHROPIC_ENVS $var=${!var}"
done

# Start Happy daemon as workspace user with ANTHROPIC_ env vars
log "Starting Happy daemon as workspace user..."
if [ -n "$ANTHROPIC_ENVS" ]; then
    log "Propagating ANTHROPIC_* environment variables to Happy daemon"
    su - workspace -c "env $ANTHROPIC_ENVS happy daemon start" &
else
    su - workspace -c "happy daemon start" &
fi

echo "Accepting connections via SSH..."
tail -f /dev/null
