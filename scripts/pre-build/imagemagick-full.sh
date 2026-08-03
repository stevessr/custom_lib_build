#!/bin/bash
#
# pre-build/imagemagick-full.sh — 从 PKGBUILD 剔除仅存在于 AUR 的依赖。
#
# imagemagick-full 的 PKGBUILD 在 depends/makedepends 里声明了 7 个只在
# AUR 存在的包（官方仓库没有）：
#   autotrace-nomagick  dmalloc  flif  libfpx  libumem-git
#   magickcache-git  pstoedit-nomagick
# CI 容器只配置官方仓库，`makepkg -s` 安装依赖时 pacman 报
# "target not found: ..." 直接失败。
#
# ImageMagick 的 configure 对每个可选中件都是宽容的：对应库/程序缺失时
# 只禁用该 delegate 并继续构建，不会报错。因此把名字从 depends 和
# makedepends 数组中删掉即可，其余官方仓库依赖照常由 makepkg -s 安装。
# 构建产出的包因此也不再声明这些 AUR 依赖，与内容一致 —— 这些特性
# （FLIF/autotrace/pstoedit/FPX/umem/dmalloc/pagemap 缓存）在 CI 构建里
# 不启用。
#
# 每个名字都带校验：如果上游改了数组书写格式导致 sed 没删干净，会在这里
# 显式失败，而不是等 makepkg 到依赖解析阶段才发现。
#
# Usage: pre-build.sh <pkg-dir> <pkg-name>
#
set -euo pipefail

PKG_DIR="$1"
PKG="$2"
PKGBUILD="$PKG_DIR/PKGBUILD"

AUR_ONLY_DEPS=(
    autotrace-nomagick
    dmalloc
    flif
    libfpx
    libumem-git
    magickcache-git
    pstoedit-nomagick
)

echo "  [hook] Stripping AUR-only deps from $PKG PKGBUILD ..."

for dep in "${AUR_ONLY_DEPS[@]}"; do
    # 数组条目格式为一行一个引号包裹的名字；行内只允许空白与引号。
    sed -i "/^[[:space:]]*'${dep}'[[:space:]]*$/d" "$PKGBUILD"
done

# --with-dmalloc 必须一并移除：ImageMagick 的 configure 在探测 dmalloc 后
# 会无条件把 -ldmalloc 加入 LIBS（即使库不存在，链接失败也不回退），从而
# 污染后续所有 conftest 链接 —— 典型症状是所有 AC_CHECK_SIZEOF 报
# "cannot compute sizeof"，config.log 里每个 gcc 链接行都有
# "/usr/bin/ld: cannot find -ldmalloc"。其余缺失库（flif/fpx/umem 等）的
# configure 探测都是安全降级的，不会污染 LIBS，因此只需要处理 dmalloc。
sed -i '/^[[:space:]]*--with-dmalloc[[:space:]]*\\$/d' "$PKGBUILD"

# 校验：真实解析 depends/makedepends 数组（depends 定义在 package_*()
# 函数体内，不能只靠顶层 source）。提取出数组文本后用 eval 求值，再对
# 求值结果做精确匹配。若上游把数组改成单行格式（行级 sed 漏删），这里
# 能看到残留名字并显式失败。任何解析失败（eval 报错）也会让命令替换
# 非零退出，hook 立即失败 —— 不会静默放过。
deps_out="$(bash -c '
    set -euo pipefail
    f="$1"
    makedepends=()
    depends=()
    eval "$(sed -n "/^[[:space:]]*makedepends=(/,/)$/p" "$f")"
    eval "$(sed -n "/^[[:space:]]*depends=(/,/)$/p" "$f")"
    printf "%s\n" "${makedepends[@]}" "${depends[@]}"
' _ "$PKGBUILD")"
if printf '%s\n' "$deps_out" \
    | grep -qxE '(autotrace-nomagick|dmalloc|flif|libfpx|libumem-git|magickcache-git|pstoedit-nomagick)'; then
    echo "  [hook] ERROR: AUR-only dep still present in depends/makedepends after strip" >&2
    exit 1
fi

echo "  [hook] ✓ Removed AUR-only deps from depends/makedepends of $PKG"