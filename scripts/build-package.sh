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

# ── Source: custom PKGBUILD or AUR? ────────────────────────────────
CUSTOM_PKG="$GITHUB_WORKSPACE/custom-pkgs/$PKG"
IS_CUSTOM=0
if [ -f "$CUSTOM_PKG/PKGBUILD" ]; then
    IS_CUSTOM=1
    echo -e "${BLUE}  Using custom PKGBUILD: custom-pkgs/$PKG${NC}"
fi

# ── Prepare build dir (custom PKGBUILD or AUR clone) ────────────────
PKG_DIR="$BUILD_DIR/$PKG"

if [ "$IS_CUSTOM" -eq 1 ]; then
    # Custom PKGBUILD: copy from repo, no git clone
    rm -rf "$PKG_DIR"
    mkdir -p "$PKG_DIR"
    cp -a "$CUSTOM_PKG/." "$PKG_DIR/"
else
    # Determine the AUR git repo name (PackageBase): split packages like
    # rustrover-jre live in the rustrover.git repo. Query AUR RPC.
    AUR_REPO="$PKG"
    BASE_INFO=$(curl -fsSL --max-time 10 \
        "https://aur.archlinux.org/rpc/v5/info?arg[]=$PKG" 2>/dev/null \
        | jq -r '.results[0].PackageBase // empty' 2>/dev/null)
    if [ -n "$BASE_INFO" ] && [ "$BASE_INFO" != "$PKG" ]; then
        AUR_REPO="$BASE_INFO"
        echo -e "${YELLOW}  Split package: cloning $AUR_REPO.git (base of $PKG)${NC}"
    fi

    if [ -d "$PKG_DIR/.git" ]; then
        cd "$PKG_DIR"
        git pull --ff-only 2>&1 | sed 's/^/  /' || true
    fi

    if [ ! -d "$PKG_DIR/.git" ]; then
        rm -rf "$PKG_DIR"
        git clone --depth=1 "https://aur.archlinux.org/$AUR_REPO.git" "$PKG_DIR" 2>&1 | sed 's/^/  /'
    fi
fi

# ── Pre-build hook (per-package tweaks) ────────────────────────────
HOOK="$GITHUB_WORKSPACE/scripts/pre-build/$PKG.sh"
if [ -f "$HOOK" ]; then
    echo -e "${BLUE}  Running pre-build hook: scripts/pre-build/$PKG.sh${NC}"
    bash "$HOOK" "$PKG_DIR" "$PKG" || {
        echo -e "${RED}  ✗ Pre-build hook failed for $PKG${NC}"
        exit 1
    }
fi

cd "$PKG_DIR"

# ── Determine current version ────────────────────────────────────────
echo -e "${BLUE}  Determining current version of $PKG ...${NC}"

if [ "$IS_CUSTOM" -eq 1 ]; then
    # Custom PKGBUILD: npm-style packages version via pkgver() at build
    # time; use a unique marker so we always rebuild (npm versions are
    # dynamic and makepkg resolves them via pkgver())
    current_ver="custom-$(date -u +%Y%m%d%H%M)"
    echo "  Custom PKGBUILD — will always rebuild"
elif [[ "$PKG" == *-git ]]; then
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
    # Sanitize filename: epoch colons (e.g. kiro-ide-2:1.0.242) are rejected
    # by GitHub artifact upload. Replace ':' with '_' everywhere.
    destname=$(basename "$pkgfile" | tr ':' '_')
    cp "$pkgfile" "$REPO_DIR/$destname"
    echo -e "${GREEN}  ✓ Built: $destname${NC}"
    built=1
done

if [ "$built" -eq 0 ]; then
    echo -e "${RED}  ✗ No package files produced${NC}"
    exit 1
fi

echo "version=$current_ver" > "$PKG_OUTPUT"
echo "skipped=false" >> "$PKG_OUTPUT"

echo -e "${GREEN}  ✓ Done: $PKG${NC}"
