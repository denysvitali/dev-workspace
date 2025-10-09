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
    if [ -n "$TAILSCALE_AUTH_KEY" ]; then
        log "Shutting down Tailscale..."
        tailscale down || true
        pkill tailscaled || true
    fi
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

# Validate environment variables
if [ -n "$TAILSCALE_AUTH_KEY" ] && [ ${#TAILSCALE_AUTH_KEY} -lt 20 ]; then
    error_exit "TAILSCALE_AUTH_KEY appears to be invalid (too short)"
fi

# Setup Tailscale if auth key is provided
if [ -n "$TAILSCALE_AUTH_KEY" ]; then
    log "Starting Tailscale with provided auth key..."

    # Create necessary directories
    mkdir -p /var/lib/tailscale /var/run/tailscale

    # Create backup resolv.conf to prevent Tailscale DNS warnings
    if [ ! -f /etc/resolv.pre-tailscale-backup.conf ] && [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf /etc/resolv.pre-tailscale-backup.conf
    fi

    # Start tailscaled with retry logic
    retry 3 tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
    sleep 3

    # Build tailscale up command with optional exit node and advertise exit flags
    TAILSCALE_ARGS="--authkey=$TAILSCALE_AUTH_KEY --hostname=${HOSTNAME:-workspace} --ssh"

    # Enable exit node functionality if requested
    if [ "${TAILSCALE_EXIT_NODE:-false}" = "true" ]; then
        log "Configuring as Tailscale exit node..."
        TAILSCALE_ARGS="$TAILSCALE_ARGS --advertise-exit-node"
    fi

    # Accept routing if this should be an exit node
    if [ "${TAILSCALE_ACCEPT_ROUTES:-false}" = "true" ]; then
        TAILSCALE_ARGS="$TAILSCALE_ARGS --accept-routes"
    fi

    # Add custom tags if provided
    if [ -n "$TAILSCALE_TAGS" ]; then
        TAILSCALE_ARGS="$TAILSCALE_ARGS --advertise-tags=$TAILSCALE_TAGS"
    fi

    # Connect to Tailscale with retry logic
    retry 3 tailscale up $TAILSCALE_ARGS
    log "Tailscale started successfully"

    # If configured as exit node, ensure IP forwarding is enabled
    if [ "${TAILSCALE_EXIT_NODE:-false}" = "true" ]; then
        log "Enabling IP forwarding for exit node functionality..."
        echo 'net.ipv4.ip_forward = 1' | tee /etc/sysctl.d/99-tailscale.conf
        echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
        sysctl -p /etc/sysctl.d/99-tailscale.conf
        log "IP forwarding enabled for exit node"
    fi
else
    log "No Tailscale auth key provided, skipping Tailscale setup"
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

if [ -n "$TAILSCALE_AUTH_KEY" ]; then
    log "Tailscale status:"
    tailscale status || true

    if [ "${TAILSCALE_EXIT_NODE:-false}" = "true" ]; then
        log "Exit node status: Active"
        tailscale status --self | grep "Exit node" || log "Exit node advertised but not yet approved"
    fi
fi

echo "Accepting connections via SSH..."
tail -f /dev/null
