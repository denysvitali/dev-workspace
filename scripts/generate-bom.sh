#!/bin/sh
# Generate Bill of Materials (BOM) for the container image
# Usage: generate-bom.sh [ARCH] [RELEASE_TAG]
# ARCH: Architecture label (e.g., "AMD64", "ARM64")
# RELEASE_TAG: Optional release tag to include in the BOM

ARCH="${1:-Unknown}"
RELEASE_TAG="${2:-}"

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
echo "| Claude Code | $($NPM_PREFIX/bin/claude --version 2>/dev/null || echo N/A) |"
echo "| Happy Coder | $($NPM_PREFIX/bin/happy --version 2>/dev/null || echo N/A) |"
echo "| Node.js | $(node --version 2>/dev/null || echo N/A) |"
echo "| npm | $(npm --version 2>/dev/null || echo N/A) |"
echo "| Python | $(python3 --version 2>/dev/null | cut -d" " -f2 || echo N/A) |"
echo "| Go | $(go version 2>/dev/null | cut -d" " -f3 || echo N/A) |"
echo "| Rust | N/A (workspace user only) |"
echo "| Git | $(git --version 2>/dev/null | cut -d" " -f3 || echo N/A) |"
echo "| kubectl | $(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion || echo N/A) |"
echo "| GitHub CLI | $(gh --version 2>/dev/null | head -1 | cut -d" " -f3 || echo N/A) |"
echo "| Nix | $(/home/workspace/.nix-profile/bin/nix --version 2>/dev/null | cut -d" " -f3 || echo N/A) |"
echo "| devenv | $(/home/workspace/.nix-profile/bin/devenv version 2>/dev/null || echo N/A) |"
echo ""
echo "## System Packages"
echo "\`\`\`"
apk list --installed 2>/dev/null | head -50 || echo "Unable to list packages"
echo "... (truncated)"
echo "\`\`\`"
