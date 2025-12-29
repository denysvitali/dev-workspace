#!/bin/sh
# Generate Bill of Materials (BOM) for the container image
# Usage: generate-bom.sh [ARCH] [RELEASE_TAG]
# ARCH: Architecture label (e.g., "AMD64", "ARM64")
# RELEASE_TAG: Optional release tag to include in the BOM

ARCH="${1:-Unknown}"
RELEASE_TAG="${2:-}"

# Helper function to get version safely (suppress interactive prompts)
get_version() {
    command -v "$1" >/dev/null 2>&1 && timeout 5 "$@" 2>/dev/null </dev/null | head -1 || echo "N/A"
}

echo "# Bill of Materials (BOM) - ${ARCH}"
if [ -n "$RELEASE_TAG" ]; then
    echo "Release: ${RELEASE_TAG}"
fi
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
echo "## Base Image"
grep -E "^(NAME|VERSION|ID)=" /etc/os-release 2>/dev/null | sed "s/^/- /" || echo "- Unknown"
echo ""
echo "## Development Tools"
echo "| Tool | Version |"
echo "|------|---------|"
NPM_PREFIX=$(npm config get prefix 2>/dev/null || echo "/usr")
CLAUDE_VERSION=$(get_version $NPM_PREFIX/bin/claude --version 2>/dev/null || echo "N/A")
HAPPY_VERSION=$(npm list -g happy-coder 2>/dev/null | grep happy-coder | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1 || echo "N/A")
echo "| Claude Code | ${CLAUDE_VERSION} |"
echo "| Happy Coder | ${HAPPY_VERSION} |"
echo "| Node.js | $(get_version node --version) |"
echo "| npm | $(get_version npm --version) |"
echo "| Python | $(python3 --version 2>/dev/null | cut -d' ' -f2 || echo N/A) |"
echo "| Go | $(go version 2>/dev/null | cut -d' ' -f3 || echo N/A) |"
echo "| Rust | N/A (workspace user only) |"
echo "| Git | $(git --version 2>/dev/null | cut -d' ' -f3 || echo N/A) |"
echo "| kubectl | $(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion 2>/dev/null || echo N/A) |"
echo "| GitHub CLI | $(gh --version 2>/dev/null | head -1 | cut -d' ' -f3 || echo N/A) |"
echo "| Nix | $(get_version /home/workspace/.nix-profile/bin/nix --version | cut -d' ' -f3 2>/dev/null || echo "N/A") |"
echo "| devenv | $(get_version /home/workspace/.nix-profile/bin/devenv version 2>/dev/null || echo "N/A") |"
echo ""
echo "## System Packages"
echo "\`\`\`"
apk list --installed 2>/dev/null | head -50 || echo "Unable to list packages"
echo "... (truncated)"
echo "\`\`\`"
