#!/bin/bash
#
# pre-build/libfpx.sh — 修复 libfpx 死源 URL（archive.org 回退）。
#
# libfpx 的源文件托管在 imagemagick.org/archive/delegates/ 但该目录已不复存在
# （404）。利用 archive.org 回退获取。
#
# Usage: pre-build.sh <pkg-dir> <pkg-name>
set -euo pipefail
PKG_DIR="$1"
PKG="$2"
echo "  [hook] Rewriting dead source URL for $PKG (archive.org fallback)"
sed -i 's|https://imagemagick\.org/archive/delegates/|https://web.archive.org/web/2020id_/https://imagemagick.org/archive/delegates/|g' "$PKG_DIR/PKGBUILD"