#!/bin/bash
#
# pre-build/ccline-bin.sh — 预创建 ~/.claude 目录
#
# ccline-bin 的 PKGBUILD package() 检查 $HOME/.claude 是否存在，
# 不存在则构建失败。构建在干净的 builder HOME 中进行，需要预创建。
#
# 该包把二进制装到 $HOME/.claude/ccline/ 再链接到 /usr/bin，
# 安装到真实系统时 $HOME 是用户家目录，需要用户先安装 claude-code。
#
# Usage: pre-build.sh <pkg-dir> <pkg-name>
#
set -euo pipefail

PKG_DIR="$1"
PKG="$2"

echo "  [hook] Creating \$HOME/.claude for $PKG ..."
mkdir -p "$HOME/.claude"
echo "  [hook] Done: $HOME/.claude exists"
