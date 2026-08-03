#!/bin/bash
#
# pre-build/imagemagick-full.sh — 构建前安装 AUR-only 构建依赖。
#
# imagemagick-full 的 depends/makedepends 里有 7 个只在 AUR 存在的包：
#   autotrace-nomagick  dmalloc  flif  libfpx  libumem-git
#   magickcache-git  pstoedit-nomagick
# CI 容器默认只有官方仓库，`makepkg -s` 解析依赖时直接报
# "target not found: ..."。本钩子在 makepkg 之前把这 7 个依赖装进容器：
#   1. 优先从本自定义仓库（arch_lib 的 latest release）安装 ——
#      已发布的（如 libumem-git）直接 pacman -S 下载安装；
#   2. 仓库里没有的（autotrace-nomagick dmalloc flif libfpx
#      magickcache-git pstoedit-nomagick）从 AUR git 克隆后
#      makepkg 构建，再 pacman -U 安装。
# 这样 imagemagick-full 可以全特性构建（--with-dmalloc 等保留），
# 产出的包也真实声明这些依赖，与本仓发布内容一致。
#
# 临时注册的 arch_lib 仓库段用 SigLevel = Never：容器是一次性构建
# 环境，只为让 pacman 能解析到本仓的包；终端用户侧的签名校验不受影响。
#
# 运行身份：builder（build-package.sh 以 sudo -EHu builder 运行整个
# 脚本）；pacman 安装操作需要 sudo（builder 已配 NOPASSWD: SETENV: ALL）。
#
# Usage: pre-build.sh <pkg-dir> <pkg-name>
#
set -euo pipefail

PKG_DIR="$1"
PKG="$2"

REPO_NAME="arch_lib"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-stevessr/custom_lib_build}"
REPO_URL="https://github.com/${GITHUB_REPOSITORY}/releases/download/latest"
AUR_DEPS_DIR="/tmp/aur-deps"
mkdir -p "$AUR_DEPS_DIR"

AUR_ONLY_DEPS=(
    libumem-git
    dmalloc
    libfpx
    flif
    pstoedit-nomagick    # must come BEFORE autotrace-nomagick (its dep)
    autotrace-nomagick
    magickcache-git
)

# ── 1. 把本仓注册进 pacman（幂等），并刷新数据库 ─────────────────
if ! grep -q "^\[${REPO_NAME}\]$" /etc/pacman.conf 2>/dev/null; then
    echo "  [hook] Adding repo [$REPO_NAME] ($REPO_URL) to pacman.conf"
    {
        printf '\n[%s]\n' "$REPO_NAME"
        printf 'SigLevel = Never\n'
        printf 'Server = %s\n' "$REPO_URL"
    } | sudo tee -a /etc/pacman.conf >/dev/null
fi
sudo pacman -Sy --noconfirm >/tmp/aur-deps/pacman-sy.log 2>&1 || {
    echo "  [hook] ✗ pacman -Sy failed (network?)" >&2
    tail -5 /tmp/aur-deps/pacman-sy.log >&2
    exit 1
}

# ── 2. 依次安装 7 个依赖：本仓优先，否则 AUR 构建回退 ──────────────
# 按包的源补丁（prepare() 注入 / 源 URL 修复等），在 makepkg 前执行。
# 扩展此函数以处理更多 AUR 包的编译兼容性问题。
patch_aur_pkgbuild() {
    local p="$1" d="$2"
    case "$p" in
        pstoedit-nomagick)
            # g++16 + -std=gnu++11: constexpr 函数体必须单一 return 语句。
            # 注入 prepare() 在 build() 前修补 fillpoly.cpp，移除 constexpr。
            if ! grep -q '^prepare()' "$d/PKGBUILD" 2>/dev/null; then
                cat >> "$d/PKGBUILD" <<'PREPARE_EOF'
prepare() {
    cd "pstoedit-${pkgver}"
    sed -i 's/^constexpr int octant(double a, double b)/int octant(double a, double b)/' src/fillpoly.cpp
}
PREPARE_EOF
            fi
            ;;
    esac
}

build_from_aur() {
    local p="$1"
    local d="$AUR_DEPS_DIR/$p"
    local logfile="$AUR_DEPS_DIR/$p-build.log"
    echo "  [hook] Building AUR dep: $p ..."
    rm -rf "$d"
    mkdir -p "$d"
    if ! ( cd "$d" && git clone -q --depth=1 "https://aur.archlinux.org/$p.git" . ); then
        echo "  [hook] ✗ git clone failed for AUR dep $p" >&2
        exit 1
    fi
    # makepkg 7.1 把 BUILDENV 声明为 readonly，部分 AUR PKGBUILD（如
    # autotrace-nomagick）会 `BUILDENV+=('!check')` 直接报错。删掉该行。
    sed -i '/^[[:space:]]*BUILDENV/d' "$d/PKGBUILD"
    # 部分 AUR 源文件托管在 imagemagick.org/archive/ 但该目录已不复存在
    # （libfpx 等）。尝试用 archive.org 回退获取。
    sed -i 's|https://imagemagick\.org/archive/delegates/|https://web.archive.org/web/2020id_/https://imagemagick.org/archive/delegates/|g' "$d/PKGBUILD"
    patch_aur_pkgbuild "$p" "$d"
    # makepkg -s 会装该 AUR 包自己的依赖（官方 + 本仓均可解析）。
    # --skippgpcheck：容器连不上 keyserver，且 sha256 已校验通过，
    # PGP 签名校验在此环境无意义。
    if ! ( cd "$d" && makepkg -s --noconfirm --needed --skippgpcheck >"$logfile" 2>&1 ); then
        echo "  [hook] ✗ makepkg failed for AUR dep $p — log tail:" >&2
        tail -30 "$logfile" >&2
        exit 1
    fi
    mapfile -t pkgs < <( compgen -G "$d"/*.pkg.tar.zst | grep -v -- '-debug-' || true )
    if [ "${#pkgs[@]}" -eq 0 ]; then
        echo "  [hook] ✗ AUR dep $p produced no package" >&2
        exit 1
    fi
    sudo pacman -U --noconfirm "${pkgs[@]}" >/dev/null
    echo "  [hook] ✓ Installed AUR dep: $p"
}

echo "  [hook] Installing AUR-only build deps for $PKG ..."
for p in "${AUR_ONLY_DEPS[@]}"; do
    if pacman -Q "$p" >/dev/null 2>&1; then
        echo "  [hook] already installed: $p"
        continue
    fi
    if sudo pacman -S --noconfirm --needed --logfile "$AUR_DEPS_DIR/pacman-$p.log" "$p" >/dev/null 2>&1; then
        echo "  [hook] ✓ Installed $p from repo $REPO_NAME"
        continue
    fi
    echo "  [hook] $p not in repos — falling back to AUR build"
    build_from_aur "$p"
done

# ── 3. 全部就位校验；有缺失即中止，日志可见原因 ─────────────────────
missing=()
for p in "${AUR_ONLY_DEPS[@]}"; do
    pacman -Q "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "  [hook] ✗ Still missing build deps: ${missing[*]}" >&2
    exit 1
fi
echo "  [hook] ✓ All build deps for $PKG installed"