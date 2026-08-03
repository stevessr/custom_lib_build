#!/bin/bash
#
# pre-build/pstoedit-nomagick.sh — g++16 兼容：build() 注入 -std=gnu++17。
#
# pstoedit 4.02 的 configure 会把 CXXFLAGS 设为 -std=gnu++11（C++11 constexpr
# 规则：函数体必须单一 return 语句），在 g++16 下 fillpoly.cpp/drvpdf.cpp 等
# 报 "body of 'constexpr' function not a return-statement"。C++17 的 relaxed
# constexpr 允许多语句函数体。注入 CXXFLAGS="${CXXFLAGS} -std=gnu++17" 后，
# configure 看到 CXXFLAGS 已设置就不会再加 -std=gnu++11（last wins）。
#
# Usage: pre-build.sh <pkg-dir> <pkg-name>
set -euo pipefail
PKG_DIR="$1"
PKG="$2"
echo "  [hook] CXXFLAGS=-std=gnu++17 override for $PKG (gcc16 constexpr)"
sed -i 's|^    cd "pstoedit-\${pkgver}"$|    cd "pstoedit-${pkgver}"\n    CXXFLAGS="${CXXFLAGS} -std=gnu++17"|' "$PKG_DIR/PKGBUILD"