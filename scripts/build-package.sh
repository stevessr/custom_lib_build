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
# Skip logic: if version == last recorded version, exit 0 without building.
# The build workflow reuses old package files from the previous `latest`
# Release when a package is skipped.
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

# Keep package assets below the GitHub Release per-asset limit. The
# limit is configurable for self-hosted mirrors or stricter policies.
MAX_RELEASE_ASSET_BYTES="${MAX_RELEASE_ASSET_BYTES:-2147483648}"

# zstd level 19 is substantially smaller than Arch's default level 9 while
# remaining within the normal (non-`--ultra`) zstd range.
PACKAGE_ZSTD_LEVEL="${PACKAGE_ZSTD_LEVEL:-19}"
if [[ ! "$PACKAGE_ZSTD_LEVEL" =~ ^([1-9]|1[0-9])$ ]]; then
    echo -e "${RED}  ✗ PACKAGE_ZSTD_LEVEL must be an integer from 1 to 19${NC}"
    exit 1
fi

if [[ ! "$MAX_RELEASE_ASSET_BYTES" =~ ^[1-9][0-9]*$ ]]; then
    echo -e "${RED}  ✗ MAX_RELEASE_ASSET_BYTES must be a positive integer${NC}"
    exit 1
fi

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
    # Failure is non-fatal (fall back to $PKG) — a transient network blip
    # must not kill the whole build via the pipefail below.
    AUR_REPO="$PKG"
    BASE_INFO=$(curl -fsSL --max-time 10 --retry 5 --retry-all-errors --retry-delay 2 \
        "https://aur.archlinux.org/rpc/v5/info?arg[]=$PKG" 2>/dev/null \
        | jq -r '.results[0].PackageBase // empty' 2>/dev/null) || true
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
        # AUR 偶发 TLS EOF/网络抖动；克隆加重试，避免一次失败杀掉整个构建
        mkdir -p "$BUILD_DIR"
        clone_ok=0
        for attempt in 1 2 3 4 5; do
            if git clone --depth=1 "https://aur.archlinux.org/$AUR_REPO.git" "$PKG_DIR" >/dev/null 2>&1; then
                clone_ok=1
                break
            fi
            echo "  (clone $AUR_REPO attempt $attempt failed; retrying)"
            sleep 5
        done
        if [ "$clone_ok" -ne 1 ]; then
            echo -e "${RED}  ✗ git clone failed for $AUR_REPO${NC}" >&2
            exit 1
        fi
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
echo -e "${YELLOW}  Building $PKG (zstd level $PACKAGE_ZSTD_LEVEL) ...${NC}"

# Use a per-build config so the repository's compression policy does not
# mutate the runner's /etc/makepkg.conf or any user-level configuration.
MAKEPKG_CONFIG="$(mktemp "${TMPDIR:-/tmp}/makepkg.conf.XXXXXX")"
trap 'rm -f "$MAKEPKG_CONFIG"' EXIT
MAKEPKG_BASE_CONFIG="${MAKEPKG_CONF:-/etc/makepkg.conf}"
if [ ! -r "$MAKEPKG_BASE_CONFIG" ]; then
    echo -e "${RED}  ✗ makepkg config not readable: $MAKEPKG_BASE_CONFIG${NC}"
    exit 1
fi
cp "$MAKEPKG_BASE_CONFIG" "$MAKEPKG_CONFIG"
printf '\n# arch_lib package-size policy\nPKGEXT=.pkg.tar.zst\nCOMPRESSZST=(zstd -c -T0 -%s -)\n' \
    "$PACKAGE_ZSTD_LEVEL" >> "$MAKEPKG_CONFIG"

# ── 注册本仓 pacman 源：让包的 depends/makedepends 里的本仓包也能被
# makepkg -s 解析（例如 autotrace-nomagick→pstoedit-nomagick）。幂等。
# 容器是一次性构建环境，SigLevel=Never 只为解析用，不影响终端用户。
if ! grep -q '^\[arch_lib\]$' /etc/pacman.conf 2>/dev/null; then
    {
        printf '\n[arch_lib]\n'
        printf 'SigLevel = Never\n'
        printf 'Server = https://github.com/%s/releases/download/latest\n' "${GITHUB_REPOSITORY:-stevessr/custom_lib_build}"
    } | sudo -n tee -a /etc/pacman.conf >/dev/null 2>&1 || true
    sudo -n pacman -Sy --noconfirm >/dev/null 2>&1 || true
fi

# --skippgpcheck：容器连不上 keyserver，且 sha256 已校验通过（PGP
# 签名校验在此环境无意义，但对部分 AUR 包会直接中断构建）。
if ! makepkg --config "$MAKEPKG_CONFIG" -s --noconfirm --needed --skippgpcheck 2>&1 | sed 's/^/  /'; then
    echo -e "${RED}  ✗ Build failed for $PKG${NC}"
    # ── Diagnostics: toolchain + failing configure logs ──────────────
    # Printed so CI failures can be debugged from the job log alone
    # (config.log is not otherwise uploaded). Conftest compile/link/run
    # evidence lines tell link errors vs. runtime failures (e.g. $? = 139).
    echo -e "${YELLOW}  ── build diagnostics ──${NC}"
    echo "  gcc: $(gcc --version 2>/dev/null | head -1)"
    echo "  ld:  $(ld --version 2>/dev/null | head -1)"
    echo "  cwd: $(pwd)"
    echo "  disk: $(df -h "$BUILD_DIR" 2>/dev/null | tail -1)"
    shopt -s nullglob
    for clog in "$PKG_DIR"/src/*/config.log "$PKG_DIR"/src/config.log; do
        [ -f "$clog" ] || continue
        echo "  >>> $clog"
        grep -nE 'conftest|error:|Segmentation|cannot ' "$clog" | tail -25
        echo "  ── tail of config.log ──"
        tail -25 "$clog"
    done
    shopt -u nullglob
    exit 1
fi

# Validate every package before copying anything. A pacman package is an
# atomic archive: blindly splitting the .pkg.tar.zst would make it unusable
# by pacman and by repo-add. Oversized packages need a PKGBUILD-level split.
shopt -s nullglob
built_files=()
for pkgfile in "$PKG_DIR"/*.pkg.tar.zst; do
    name=$(pacman -Qip "$pkgfile" 2>/dev/null | grep '^Name' | awk '{print $3}') || continue
    [ -n "$name" ] || continue

    artifact_size=$(stat -c '%s' "$pkgfile")
    if (( artifact_size > MAX_RELEASE_ASSET_BYTES )); then
        size_mib=$(( (artifact_size + 1048575) / 1048576 ))
        limit_mib=$(( (MAX_RELEASE_ASSET_BYTES + 1048575) / 1048576 ))
        echo -e "${RED}  ✗ $name is ${size_mib} MiB; GitHub Release limit is ${limit_mib} MiB${NC}"
        echo "  Split the PKGBUILD into pacman split packages instead of splitting this archive."
        exit 1
    fi
    built_files+=("$pkgfile")
done

if [ "${#built_files[@]}" -eq 0 ]; then
    echo -e "${RED}  ✗ No package files produced${NC}"
    exit 1
fi

# Copy built packages to repo dir after all size checks pass.
for pkgfile in "${built_files[@]}"; do
    name=$(pacman -Qip "$pkgfile" 2>/dev/null | grep '^Name' | awk '{print $3}') || continue
    [ -n "$name" ] || continue
    # Remove any old version of the same package
    rm -f "$REPO_DIR/${name}"-*.pkg.tar.* 2>/dev/null || true
    # Sanitize filename: epoch colons (e.g. kiro-ide-2:1.0.242) are rejected
    # by GitHub artifact upload. Replace ':' with '_' everywhere.
    destname=$(basename "$pkgfile" | tr ':' '_')
    cp "$pkgfile" "$REPO_DIR/$destname"
    artifact_size=$(stat -c '%s' "$pkgfile")
    size_mib=$(( (artifact_size + 1048575) / 1048576 ))
    echo -e "${GREEN}  ✓ Built: $destname (${size_mib} MiB)${NC}"
done

echo "version=$current_ver" > "$PKG_OUTPUT"
echo "skipped=false" >> "$PKG_OUTPUT"

echo -e "${GREEN}  ✓ Done: $PKG${NC}"
