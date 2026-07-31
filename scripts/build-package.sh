#!/bin/bash
#
# build-package.sh — Build a single AUR package, skipping -git packages
#                    whose upstream commit hash is unchanged.
#
# Version detection:
#   - Regular packages : static pkgver from PKGBUILD
#   - -git packages    : extract the git+ source URL from PKGBUILD and
#                        query the upstream HEAD commit via `git ls-remote`.
#                        That commit hash is compared against the last
#                        recorded one — no source download, no build.
#
# Skip logic: if version == last recorded version, exit 0 without building.
# The publish job reuses the old .pkg.tar.* from the previous release.
#
# Usage:
#   build-package.sh <pkg> <output-file>
#
# Output file receives:
#   version=<pkgver|commit-hash>
#   skipped=true|false
#
set -euo pipefail

PKG="$1"
# Output file lives INSIDE the container's workspace ($GITHUB_WORKSPACE),
# never the host path (${{ github.workspace }} does not exist in the container).
PKG_OUTPUT="${2:-$GITHUB_WORKSPACE/output-$PKG.env}"
mkdir -p "$(dirname "$PKG_OUTPUT")"
REPO_DIR="${REPO_DIR:-$GITHUB_WORKSPACE/repos/x86_64}"
BUILD_DIR="/tmp/aur-build"
LAST_VERSIONS_FILE="${LAST_VERSIONS_FILE:-$GITHUB_WORKSPACE/last-versions.txt}"
SRC_CACHE="${SRCDEST:-/tmp/aur-sources}"
export SRCDEST="$SRC_CACHE"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$REPO_DIR" "$BUILD_DIR" "$SRC_CACHE"

# ── Clone/update AUR package (PKGBUILD only) ─────────────────────────
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

# ── Determine current version ────────────────────────────────────────
echo -e "${BLUE}  Determining current version of $PKG ...${NC}"

if [[ "$PKG" == *-git ]]; then
    # -git: find first git+ source URL, query upstream HEAD commit
    git_urls="$(
        bash -c '
            source PKGBUILD 2>/dev/null
            for s in "${source[@]}"; do
                case "$s" in
                    git+*) printf "%s\n" "$s" ;;
                esac
            done
        ' 2>/dev/null || true
    )"

    first_git=$(printf '%s\n' "$git_urls" | head -n1)

    if [ -z "$first_git" ]; then
        echo -e "${YELLOW}  No git+ source found, falling back to static pkgver${NC}"
        current_ver="$(bash -c 'source PKGBUILD; echo "${pkgver:-unknown}"')"
    else
        # Strip git+ prefix and any #fragment
        url="${first_git#git+}"
        url="${url%%#*}"

        # Extract branch if present
        branch=""
        case "$first_git" in
            *#branch=*) branch="${first_git##*#branch=}" ;;
        esac

        ref="HEAD"
        [ -n "$branch" ] && ref="refs/heads/$branch"

        echo "  Upstream: $url ($ref)"
        current_ver="$(git ls-remote "$url" "$ref" 2>/dev/null | awk '{print $1}')" || current_ver=""

        if [ -z "$current_ver" ]; then
            echo -e "${RED}  ✗ git ls-remote failed for $url${NC}"
            exit 1
        fi
        echo "  Upstream commit: $current_ver"
    fi
else
    current_ver="$(bash -c 'source PKGBUILD; echo "${pkgver:-unknown}"')"
    echo "  PKGBUILD pkgver: $current_ver"
fi

# ── Skip if unchanged ────────────────────────────────────────────────
last_ver=""
if [ -f "$LAST_VERSIONS_FILE" ]; then
    last_ver=$(grep "^${PKG}=" "$LAST_VERSIONS_FILE" 2>/dev/null | cut -d= -f2- || true)
fi

if [ -n "$last_ver" ] && [ "$current_ver" = "$last_ver" ]; then
    echo -e "${YELLOW}  ⏭  Version unchanged ($current_ver) — skipping build${NC}"
    echo "version=$current_ver" > "$PKG_OUTPUT"
    echo "skipped=true" >> "$PKG_OUTPUT"
    exit 0
fi

# ── Build the package ────────────────────────────────────────────────
echo -e "${YELLOW}  Building $PKG ...${NC}"
if ! makepkg -s --noconfirm --needed 2>&1 | sed 's/^/  /'; then
    echo -e "${RED}  ✗ Build failed for $PKG${NC}"
    exit 1
fi

# Copy built packages to repo dir
shopt -s nullglob
built=0
for pkgfile in "$PKG_DIR"/*.pkg.tar.*; do
    name=$(pacman -Qip "$pkgfile" 2>/dev/null | grep '^Name' | awk '{print $3}') || continue
    [ -n "$name" ] || continue
    # Remove any old version of the same package
    rm -f "$REPO_DIR/${name}"-*.pkg.tar.* 2>/dev/null || true
    cp "$pkgfile" "$REPO_DIR/"
    echo -e "${GREEN}  ✓ Built: $(basename "$pkgfile")${NC}"
    built=1
done

if [ "$built" -eq 0 ]; then
    echo -e "${RED}  ✗ No package files produced${NC}"
    exit 1
fi

echo "version=$current_ver" > "$PKG_OUTPUT"
echo "skipped=false" >> "$PKG_OUTPUT"

echo -e "${GREEN}  ✓ Done: $PKG${NC}"
