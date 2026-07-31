#!/bin/bash
#
# pre-build/qoder-cli.sh — Pre-seed the qoder-cli binary.
#
# The official installer (https://qoder.com/install) now installs into
# $HOME/.qoder and $HOME/.local/bin instead of the current directory,
# which breaks the PKGBUILD's prepare() check (`[ -f qodercli ]`).
#
# The PKGBUILD explicitly supports a pre-placed binary:
#   "Alternative: Manually download the Linux CLI binary from
#    https://qoder.com/cli — Place it as 'qoder-cli' in this directory"
#
# Usage: pre-build.sh <pkg-dir> <pkg-name>
#
set -euo pipefail

PKG_DIR="$1"
PKG="$2"

echo "  [hook] Pre-seeding qoder-cli binary for $PKG ..."
mkdir -p "$PKG_DIR/src"

# Prefer an already-downloaded copy in the workspace cache, else fetch
CACHE="$GITHUB_WORKSPACE/.qoder-cache/qoder-cli"
if [ -f "$CACHE" ]; then
    cp "$CACHE" "$PKG_DIR/src/qoder-cli"
else
    curl -fsSL https://qoder.com/cli -o "$PKG_DIR/src/qoder-cli"
fi

chmod +x "$PKG_DIR/src/qoder-cli"
echo "  [hook] Binary ready: $(ls -lh "$PKG_DIR/src/qoder-cli" | awk '{print $5}')"
