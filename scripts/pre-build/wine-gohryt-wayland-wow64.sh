#!/bin/bash
#
# pre-build/wine-gohryt-wayland-wow64.sh — 补齐 AUR PKGBUILD 漏声明的 mold 构建依赖。
#
# AUR 包的 build() 里显式选择 mold 链接原生 ELF 侧：
#
#   export LDFLAGS+=" -fuse-ld=mold"
#
# 但 makedepends 没有声明 mold。arch-builder 镜像只预装 base-devel
# （gcc/binutils/...），不包含 mold。GCC 16 的 collect2 处理
# -fuse-ld=mold 时要求 PATH 中存在 ld.mold；缺失时不会提示 mold，
# 而是给出误导性的：
#
#   collect2: fatal error: cannot find 'ld'
#   configure: error: C compiler cannot create executables
#
# 因此 makepkg 之前从官方仓库安装 mold，并用与 configure 相同的
# -fuse-ld=mold 链接一个最小测试程序来验证（而不是只检查命令存在），
# 让依赖缺失在构建早期以明确的信息失败。
#
# 运行身份：builder（build-package.sh 以 sudo -EHu builder 运行整个
# 脚本）；pacman 安装操作需要 sudo（builder 已配 NOPASSWD: SETENV: ALL）。
#
# Usage: pre-build.sh <pkg-dir> <pkg-name>
set -euo pipefail

PKG_DIR="${1:?PKGBUILD directory required}"
PKG="${2:-wine-gohryt-wayland-wow64}"
RECIPE="$PKG_DIR/PKGBUILD"

if [ ! -f "$RECIPE" ]; then
    echo "  [hook] ✗ PKGBUILD not found: $RECIPE" >&2
    exit 1
fi

# Upstream may drop the explicit mold choice; then there is nothing to do.
if ! grep -q -- '-fuse-ld=mold' "$RECIPE"; then
    echo "  [hook] $PKG no longer uses -fuse-ld=mold; skipping mold bootstrap"
    exit 0
fi

if command -v ld.mold >/dev/null 2>&1; then
    echo "  [hook] ✓ mold linker already available: $(command -v ld.mold)"
    exit 0
fi

echo "  [hook] mold missing (required by -fuse-ld=mold); installing from repositories"
installed=0
for attempt in 1 2 3; do
    if sudo pacman -S --noconfirm --needed mold; then
        installed=1
        break
    fi
    echo "  [hook] (mold install attempt $attempt failed; retrying)" >&2
    sleep 5
done
if [ "$installed" -ne 1 ]; then
    echo "  [hook] ✗ failed to install mold from the configured repositories" >&2
    exit 1
fi

if ! command -v ld.mold >/dev/null 2>&1; then
    echo "  [hook] ✗ mold is installed but ld.mold is not in PATH" >&2
    exit 1
fi

# Prove the exact failure mode is gone: GCC's configure link test uses
# -fuse-ld=mold, so link a minimal program with the same flag.
probe_dir="$(mktemp -d)"
trap 'rm -rf "$probe_dir"' EXIT
printf 'int main(void){return 0;}\n' > "$probe_dir/probe.c"
if ! gcc -fuse-ld=mold "$probe_dir/probe.c" -o "$probe_dir/probe" 2>"$probe_dir/error.log"; then
    echo "  [hook] ✗ gcc still cannot link with -fuse-ld=mold" >&2
    sed 's/^/  [hook]   /' "$probe_dir/error.log" >&2 || true
    exit 1
fi
echo "  [hook] ✓ mold ready: $(ld.mold --version 2>/dev/null | head -1)"
