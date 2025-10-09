# Development Workspace

A containerized development workspace with SSH access and essential development tools.

## Features

- SSH and Mosh access
- Pre-installed development tools (Git, Docker clients, kubectl, etc.)
- Multiple language support (Rust, Go, Python, Node.js)
- Claude Code integration
- Modern CLI tools (ripgrep, fd, fzf, bat, exa, btop)

## Networking

**Note:** Tailscale connectivity for this workspace is managed by the [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator) instead of being bundled in the container. This provides better integration with Kubernetes networking and simplified management.

## Environment Variables

- `SSH_PUBLIC_KEY`: Your SSH public key for authentication
- `WORKSPACE_NAME`: Optional hostname for the workspace
- `ANTHROPIC_API_KEY`: Optional API key for Claude Code integration

## Usage

See your Kubernetes deployment configuration for setup details.
