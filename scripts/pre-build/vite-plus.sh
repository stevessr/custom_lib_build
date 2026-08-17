#!/bin/bash
#
# pre-build/vite-plus.sh — Resolve rustup/rust conflict before makepkg -s.
#
# vite-plus 的 makedepends 要求 rustup，但 arch-builder 镜像预装了 rust。
# rustup 与 rust 互相 conflicts，makepkg -s 安装 rustup 时 pacman 检测到
# 冲突会因 --noconfirm 默认拒绝移除 rust 而失败。
#
# rustup provides rust/cargo/rustfmt，用 rustup 替代 rust 后两种依赖
# 都能被 pacman 满足。此 hook 幂等：rustup 已安装时什么都不做。
#
# 镜像侧的永久修复见 Dockerfile（rust → rustup），此 hook 确保旧镜像
# 上也能构建成功。
#
# Usage: pre-build.sh <pkg-dir> <pkg-name>
#
set -euo pipefail

PKG_DIR="$1"
PKG="$2"

# If rustup is already installed (new image), nothing to do.
if pacman -Q rustup >/dev/null 2>&1; then
    echo "  [hook] rustup already installed — skipping"
    exit 0
fi

echo "  [hook] Replacing rust with rustup for $PKG ..."
# Remove rust (and cargo, which rust provides) then install rustup.
# rustup provides rust/cargo so no functionality is lost.
sudo -n pacman -Rns --noconfirm rust 2>/dev/null || true
sudo -n pacman -S --noconfirm --needed rustup

# Ensure a default stable toolchain is active so cargo/rustc are on PATH.
rustup default stable 2>/dev/null || true

echo "  [hook] rustup ready: $(rustc --version 2>/dev/null || echo 'unknown')"
