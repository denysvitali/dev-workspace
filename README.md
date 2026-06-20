# Development Workspace

A containerized development workspace with SSH access and essential development tools. Runs entirely as non-root for Kubernetes Pod Security Standards (restricted) compliance.

## Features

- SSH access via dropbear on port 2222 (non-privileged)
- Mosh support for mobile/unstable connections
- Pre-installed development tools (Git, Docker clients, kubectl, etc.)
- Multiple language support (Rust, Go, Python, Node.js)
- [Mise](https://mise.jdx.dev/) polyglot tool manager
- Claude Code integration
- Modern CLI tools (ripgrep, fd, fzf, bat, eza)
- Runs as non-root user (`workspace`) - no root privileges required

## Networking

**Note:** Tailscale connectivity for this workspace is managed by the [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator) instead of being bundled in the container. This provides better integration with Kubernetes networking and simplified management.

## Environment Variables

- `SSH_PUBLIC_KEY`: Your SSH public key for authentication
- `WORKSPACE_NAME`: Optional hostname for the workspace
- `ANTHROPIC_API_KEY`: Optional API key for Claude Code integration
- `MISE_GITHUB_TOKEN`: Optional GitHub PAT for Mise to avoid API rate limits when
  installing tools from GitHub releases. Falls back to `GITHUB_API_TOKEN` /
  `GITHUB_TOKEN` if unset. Persisted to `~/.config/mise/github_tokens.toml` on
  first boot (chmod 600).

## Ports

- `2222`: SSH (dropbear) - non-privileged port for rootless operation
- `60000-61000/udp`: Mosh

## Usage

See your Kubernetes deployment configuration for setup details.

### SSH Connection

```bash
ssh -p 2222 workspace@<host>
```

### Persistent Volumes

To maintain persistent data across container restarts, mount volumes at the following paths:

#### SSH Host Keys

```yaml
volumes:
  - name: ssh-host-keys
    persistentVolumeClaim:
      claimName: workspace-ssh-keys
volumeMounts:
  - name: ssh-host-keys
    mountPath: /etc/dropbear
```

#### Mise Data (Recommended)

Mise stores installed tools under `~/.local/share/mise` and config under
`~/.config/mise`. To survive container restarts, mount `/home/workspace` (or at
least those subpaths) as a persistent volume:

```yaml
volumes:
  - name: workspace-home
    persistentVolumeClaim:
      claimName: workspace-home
volumeMounts:
  - name: workspace-home
    mountPath: /home/workspace
```

### Mise Usage

Define per-project tool versions with a `mise.toml` (or `.tool-versions`) in
your project root:

```toml
[tools]
node = "22"
python = "3.12"
go = "1.23"
```

Then inside the workspace:

```bash
mise install        # install declared versions
mise use node@22    # pin a tool for the current dir
```
