#!/bin/bash
#
# build-repo.sh — Build AUR packages and generate pacman repository
#
# Reads package names from packages.txt, builds each from AUR,
# and creates a pacman-compatible repository database (repo-add).
#
# Environment:
#   GITHUB_WORKSPACE  — workspace root (set by GitHub Actions)
#   SRCDEST           — source cache directory (for makepkg)
#
set -euo pipefail

REPO_NAME="arch_lib"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
PACKAGES_FILE="${1:-$WORKSPACE/packages.txt}"
REPO_DIR="$WORKSPACE/repos/x86_64"
BUILD_DIR="/tmp/aur-build"
SRC_CACHE="${SRCDEST:-/tmp/aur-sources}"

# ── Colors ──────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ── Prepare directories ─────────────────────────────────────────────
mkdir -p "$REPO_DIR" "$BUILD_DIR" "$SRC_CACHE"

# ── Validate package list ───────────────────────────────────────────
if [ ! -f "$PACKAGES_FILE" ]; then
    echo -e "${RED}Error: packages file not found: $PACKAGES_FILE${NC}"
    exit 1
fi

# Read: strip comments, blank lines, leading/trailing whitespace
mapfile -t packages < <(
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$PACKAGES_FILE" \
        | grep -v '^$'
)

if [ ${#packages[@]} -eq 0 ]; then
    echo -e "${RED}Error: no packages defined in $PACKAGES_FILE${NC}"
    exit 1
fi

echo -e "${GREEN}═══ Building ${#packages[@]} packages ═══${NC}"
printf '  • %s\n' "${packages[@]}"

# ── Build each package ──────────────────────────────────────────────
BUILD_FAILURES=0

for pkg in "${packages[@]}"; do
    echo -e "\n${YELLOW}────────────────────────────────────────${NC}"
    echo -e "${YELLOW}  Building: $pkg${NC}"
    echo -e "${YELLOW}────────────────────────────────────────${NC}"

    PKG_DIR="$BUILD_DIR/$pkg"

    # Clone or update AUR package
    if [ -d "$PKG_DIR/.git" ]; then
        echo "  Updating existing clone..."
        cd "$PKG_DIR"
        git pull --ff-only 2>&1 | sed 's/^/  /' \
            || echo -e "${YELLOW}  Warning: git pull failed, will retry with fresh clone${NC}"
    fi

    if [ ! -d "$PKG_DIR/.git" ]; then
        rm -rf "$PKG_DIR"
        echo "  Cloning AUR/$pkg ..."
        git clone --depth=1 "https://aur.archlinux.org/$pkg.git" "$PKG_DIR" 2>&1 \
            | sed 's/^/  /' \
            || {
                echo -e "${RED}  ✗ Failed to clone $pkg${NC}"
                BUILD_FAILURES=$((BUILD_FAILURES + 1))
                continue
            }
    fi

    cd "$PKG_DIR"

    # Build — makepkg -s syncs deps via pacman (needs sudo)
    echo "  Running makepkg -s --noconfirm --needed ..."
    if makepkg -s --noconfirm --needed 2>&1 | sed 's/^/  /'; then
        # Install shellcheck:ignore SC3044
        shopt -s nullglob
        for pkgfile in "$PKG_DIR"/*.pkg.tar.*; do
            name=$(pacman -Qip "$pkgfile" 2>/dev/null \
                | grep '^Name' | awk '{print $3}') \
                || continue
            [ -n "$name" ] || continue
            echo "  Package: $name"
            # Remove any old version of the same package
            rm -f "$REPO_DIR/${name}"-*.pkg.tar.* 2>/dev/null || true
            mv "$pkgfile" "$REPO_DIR/"
            echo -e "${GREEN}  ✓ $(basename "$pkgfile")${NC}"
        done
    else
        echo -e "${RED}  ✗ Build failed for $pkg${NC}"
        BUILD_FAILURES=$((BUILD_FAILURES + 1))
    fi
done

# ── Create repository database ─────────────────────────────────────
echo -e "\n${YELLOW}════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Creating repository database${NC}"
echo -e "${YELLOW}════════════════════════════════════════${NC}"

cd "$REPO_DIR"

PKG_COUNT=$(ls -1 *.pkg.tar.* 2>/dev/null | wc -l || true)
if [ "$PKG_COUNT" -eq 0 ]; then
    echo -e "${RED}  No packages built successfully. Skipping database.${NC}"
    exit 1
fi

echo "  Packages in repo: $PKG_COUNT"

# Clean previous database
rm -f "$REPO_NAME.db.tar.gz" "$REPO_NAME.db" \
      "$REPO_NAME.files.tar.gz" "$REPO_NAME.files"

# Build new database (--remove: replace existing entries, --new: skip older)
repo-add --remove --new "$REPO_NAME.db.tar.gz" ./*.pkg.tar.* 2>&1 \
    | sed 's/^/  /'

# Symlinks for pacman compatibility
ln -sf "$REPO_NAME.db.tar.gz" "$REPO_NAME.db" 2>/dev/null || true
ln -sf "$REPO_NAME.files.tar.gz" "$REPO_NAME.files" 2>/dev/null || true

echo -e "${GREEN}  ✓ Repository database created${NC}"

# ── Summary ─────────────────────────────────────────────────────────
if [ "$BUILD_FAILURES" -gt 0 ]; then
    echo -e "\n${YELLOW}Warning: $BUILD_FAILURES package(s) failed❮${NC}"
fi

echo -e "\n${GREEN}═══ Build complete ═══${NC}"
echo "  Repo: $REPO_DIR"
ls -lh --ignore='*.tar.gz.old' "$REPO_DIR/" 2>/dev/null | sed 's/^/  /'
