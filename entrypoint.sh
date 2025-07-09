#!/bin/bash

set -e

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting workspace container..."

# Generate SSH host keys if they don't exist
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    log "Generating SSH host keys..."
    sudo ssh-keygen -A
fi

# Start sshd daemon in the background
sudo /usr/sbin/sshd -D &

# Setup Tailscale if auth key is provided
if [ -n "$TAILSCALE_AUTH_KEY" ]; then
    log "Starting Tailscale with provided auth key..."
    sudo tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
    sleep 2
    sudo tailscale up --authkey="$TAILSCALE_AUTH_KEY" --hostname="${HOSTNAME:-workspace}" --ssh
    log "Tailscale started successfully"
else
    log "No Tailscale auth key provided, skipping Tailscale setup"
fi

# Setup SSH keys if provided
if [ -n "$SSH_PUBLIC_KEY" ]; then
    log "Setting up SSH public key..."
    mkdir -p /home/workspace/.ssh
    echo "$SSH_PUBLIC_KEY" > /home/workspace/.ssh/authorized_keys
    chmod 600 /home/workspace/.ssh/authorized_keys
    chmod 700 /home/workspace/.ssh
    log "SSH public key configured"
fi

# Set workspace name if provided
if [ -n "$WORKSPACE_NAME" ]; then
    log "Setting workspace name to: $WORKSPACE_NAME"
    sudo hostnamectl set-hostname "$WORKSPACE_NAME" 2>/dev/null || true
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
    sudo tailscale status || true
fi

# Keep container running
log "Keeping container alive..."
while true; do
    sleep 60
    # Health check - ensure services are running
    if ! pgrep -x "sshd" > /dev/null; then
        log "SSH daemon not running, restarting..."
        sudo service ssh restart
    fi
done
