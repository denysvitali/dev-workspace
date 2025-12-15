# Development Workspace

A containerized development workspace with SSH access and essential development tools. Runs entirely as non-root for Kubernetes Pod Security Standards (restricted) compliance.

## Features

- SSH access via dropbear on port 2222 (non-privileged)
- Mosh support for mobile/unstable connections
- Pre-installed development tools (Git, Docker clients, kubectl, etc.)
- Multiple language support (Rust, Go, Python, Node.js)
- Nix package manager (single-user mode) with devenv
- Claude Code integration
- Modern CLI tools (ripgrep, fd, fzf, bat, exa, btop)
- Runs as non-root user (`workspace`) - no root privileges required

## Networking

**Note:** Tailscale connectivity for this workspace is managed by the [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator) instead of being bundled in the container. This provides better integration with Kubernetes networking and simplified management.

## Environment Variables

- `SSH_PUBLIC_KEY`: Your SSH public key for authentication
- `WORKSPACE_NAME`: Optional hostname for the workspace
- `ANTHROPIC_API_KEY`: Optional API key for Claude Code integration

## Ports

- `2222`: SSH (dropbear) - non-privileged port for rootless operation
- `60000-61000/udp`: Mosh

## Usage

See your Kubernetes deployment configuration for setup details.

### SSH Connection

```bash
ssh -p 2222 workspace@<host>
```

### Persistent Host Keys

To maintain persistent SSH host keys across container restarts, mount a volume at `/etc/dropbear`:

```yaml
volumes:
  - name: ssh-host-keys
    persistentVolumeClaim:
      claimName: workspace-ssh-keys
volumeMounts:
  - name: ssh-host-keys
    mountPath: /etc/dropbear
```
