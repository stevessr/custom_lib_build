#!/bin/bash
#
# pre-build/autotrace-nomagick.sh — 确保 pstoedit-nomagick 依赖就位。
#
# autotrace-nomagick 的 depends=(...) 包含 pstoedit-nomagick（AUR-only）。
# 在 CI 中，pstoedit-nomagick 可能还未被本仓库发布（首次构建时）。
# 本钩子尝试从本仓库安装，否则从 AUR 构建安装。
# 同时清理 BUILDENV 行（makepkg 7.1 readonly）。
#
# Usage: pre-build.sh <pkg-dir> <pkg-name>
set -euo pipefail
PKG_DIR="$1"
PKG="$2"

# 清理 BUILDENV（makepkg 7.1 readonly）
sed -i '/^[[:space:]]*BUILDENV/d' "$PKG_DIR/PKGBUILD"

# 确保 pstoedit-nomagick 已安装
if pacman -Q pstoedit-nomagick >/dev/null 2>&1; then
    exit 0
fi
if sudo pacman -S --noconfirm --needed pstoedit-nomagick >/dev/null 2>&1; then
    exit 0
fi
echo "  [hook] pstoedit-nomagick not in repo, building from AUR ..."
PD="/tmp/aur-deps/pstoedit-nomagick"
rm -rf "$PD"
mkdir -p "$PD"
for attempt in 1 2 3 4 5; do
    if ( cd "$PD" && git clone -q --depth=1 "https://aur.archlinux.org/pstoedit-nomagick.git" . ); then break; fi
    rm -rf "$PD"/* && true
    sleep 5
done
# 同 pstoedit-nomagick 的预构建钩子：CXXFLAGS 覆盖
sed -i 's|^    cd "pstoedit-\${pkgver}"$|    cd "pstoedit-${pkgver}"\n    CXXFLAGS="${CXXFLAGS} -std=gnu++17"|' "$PD/PKGBUILD"
if ! ( cd "$PD" && makepkg -s --noconfirm --needed --skippgpcheck >/tmp/aur-deps/autotrace-pstoedit-build.log 2>&1 ); then
    echo "  [hook] ✗ AUR build of pstoedit-nomagick failed" >&2
    tail -15 /tmp/aur-deps/autotrace-pstoedit-build.log >&2
    exit 1
fi
mapfile -t pkgs < <( compgen -G "$PD"/*.pkg.tar.zst | grep -v -- '-debug-' || true )
sudo pacman -U --noconfirm "${pkgs[@]}" >/dev/null
echo "  [hook] ✓ Installed pstoedit-nomagick from AUR (autotrace dep)"