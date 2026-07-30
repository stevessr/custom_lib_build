#!/bin/bash
#
# build-package.sh — Build a single AUR package and check if it needs updating
#
# For -git packages: sources PKGBUILD to get pkgver (commit hash based),
#                   compares against the version stored in LAST_VERSIONS_FILE.
#                   If same, skip the build entirely.
#
# Environment:
#   GITHUB_WORKSPACE    — workspace root
#   SRCDEST             — source cache (for makepkg)
#   LAST_VERSIONS_FILE  — path to a file mapping package → last-built version
#   REPO_DIR            — where to place built packages
#
set -euo pipefail

PKG="$1"
REPO_DIR="${REPO_DIR:-$GITHUB_WORKSPACE/repos/x86_64}"
BUILD_DIR="/tmp/aur-build"
LAST_VERSIONS_FILE="${LAST_VERSIONS_FILE:-$GITHUB_WORKSPACE/last-versions.txt}"
SRC_CACHE="${SRCDEST:-/tmp/aur-sources}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$REPO_DIR" "$BUILD_DIR" "$SRC_CACHE"

# ── Clone/update AUR package ─────────────────────────────────────────
PKG_DIR="$BUILD_DIR/$PKG"

if [ -d "$PKG_DIR/.git" ]; then
    cd "$PKG_DIR"
    git pull --ff-only 2>&1 | sed 's/^/  /' || true
fi

if [ ! -d "$PKG_DIR/.git" ]; then
    rm -rf "$PKG_DIR"
    git clone --depth=1 "https://aur.archlinux.org/$PKG.git" "$PKG_DIR" 2>&1 | sed 's/^/  /'
fi

cd "$PKG_DIR"

# ── Extract PKGBUILD version ─────────────────────────────────────────
# For -git packages, pkgver() runs a command that generates a version
# containing the commit hash (e.g. "r1234.a1b2c3d" or "20240101.a1b2c3d").
# We source PKGBUILD and run pkgver() to get the current version.
echo -e "${BLUE}  Reading PKGBUILD version info...${NC}"

# Source PKGBUILD in a clean sub-shell to extract metadata
pkgver_raw=""
pkgname_raw=""

# We need to source the PKGBUILD to get its variables.
# makepkg itself does this — we mimic it minimally.
eval "$(
    bash -c '
        source PKGBUILD 2>/dev/null
        echo "pkgver_raw=${pkgver@Q}"
        echo "pkgname_raw=${pkgname@Q}"
    '
)" || {
    echo -e "${RED}  ✗ Failed to parse PKGBUILD${NC}"
    exit 1
}

# For -git packages, pkgver() function generates the version dynamically.
# We need to run it to get the actual version.
if [[ "$PKG" == *-git ]]; then
    echo -e "${BLUE}  Git package detected — running pkgver()...${NC}"
    # Run pkgver() in a clean environment sourcing PKGBUILD
    current_ver="$(
        bash -c '
            source PKGBUILD 2>/dev/null
            type pkgver &>/dev/null && pkgver || echo "${pkgver:-unknown}"
        '
    )" || current_ver=""
    echo -e "  PKGBUILD pkgver  : $current_ver"
else
    current_ver="$pkgver_raw"
    echo -e "  PKGBUILD pkgver  : $current_ver"
fi

# ── Check if we already built this version ───────────────────────────
last_ver=""
if [ -f "$LAST_VERSIONS_FILE" ]; then
    last_ver=$(grep "^${PKG}=" "$LAST_VERSIONS_FILE" 2>/dev/null | cut -d= -f2- || true)
fi

if [ -n "$last_ver" ] && [ "$current_ver" = "$last_ver" ]; then
    echo -e "${YELLOW}  ⏭  Version unchanged ($current_ver), reusing cached package${NC}"
    # Copy the old package back from workspace cache if it exists
    pkg_file=$(ls "$REPO_DIR"/"${pkgname_raw}"-*.pkg.tar.* 2>/dev/null | head -1 || true)
    if [ -n "$pkg_file" ]; then
        echo -e "${GREEN}  ✓ Cached package exists: $(basename "$pkg_file")${NC}"
        echo "pkg_file=$pkg_file" >> "$GITHUB_OUTPUT"
        echo "version=$current_ver" >> "$GITHUB_OUTPUT"
        echo "skipped=true" >> "$GITHUB_OUTPUT"
        exit 0
    else
        echo -e "${YELLOW}  Cached package not found, rebuilding anyway${NC}"
    fi
fi

# ── Build the package ────────────────────────────────────────────────
echo -e "${YELLOW}  Building $PKG ...${NC}"
if makepkg -s --noconfirm --needed 2>&1 | sed 's/^/  /'; then
    shopt -s nullglob
    built=0
    for pkgfile in "$PKG_DIR"/*.pkg.tar.*; do
        name=$(pacman -Qip "$pkgfile" 2>/dev/null | grep '^Name' | awk '{print $3}') || continue
        [ -n "$name" ] || continue
        # Remove old version
        rm -f "$REPO_DIR/${name}"-*.pkg.tar.* 2>/dev/null || true
        cp "$pkgfile" "$REPO_DIR/"
        echo -e "${GREEN}  ✓ Built: $(basename "$pkgfile")${NC}"
        built=1
        # Record for GitHub Actions output
        echo "pkg_file=$REPO_DIR/$(basename "$pkgfile")" >> "$GITHUB_OUTPUT"
    done

    if [ "$built" -eq 0 ]; then
        echo -e "${RED}  ✗ No package files produced${NC}"
        exit 1
    fi

    echo "version=$current_ver" >> "$GITHUB_OUTPUT"
    echo "skipped=false" >> "$GITHUB_OUTPUT"
else
    echo -e "${RED}  ✗ Build failed for $PKG${NC}"
    exit 1
fi

echo -e "${GREEN}  ✓ Done: $PKG${NC}"