#!/bin/bash
#
# release-asset-selection.sh — 从 `latest` Release 的资产名清单中选出属于
# 某个包（含 split 同族）的包文件。
#
# 背景：build-package.yaml 的 reuse 路径原先用 "<pkg>-" 前缀匹配资产。当
# 包名恰好是另一个包名的前缀时（python-tree-sitter / python-tree-sitter-*、
# python-conda / python-conda-*、wechat / wechat-bin、android-sdk /
# android-sdk-build-tools 等），前缀匹配会把别的包的文件当成同族：
#   - maxver 取到别的包的版本，reuse artifact 内容错误；
#   - publish-release.sh 随后按错误 manifest 清理"旧文件"，会删掉别的包的
#     资产。python-tree-sitter 0.26.0 的资产就被 python-tree-sitter-objc
#     3.0.2 的 manifest 顶掉，导致所有 tree-sitter 包构建时依赖下载 404。
#
# 本脚本只接受与 PKGBUILD 声明的输出包名（pkgname，逗号分隔）完全一致的
# 包名，以及每个包名对应的 -debug 包；文件名必须严格匹配
#   <name>(-debug)?-<pkgver>-<pkgrel>-<arch>.pkg.tar.zst
# 因此 python-tree-sitter-julia 不会被当作 python-tree-sitter 的同族，
# 而 rustrover + rustrover-jre 这类真正的 split 同族仍会一起选中。
#
# Usage:
#   release-asset-selection.sh <package> <pkgname-csv> <asset-names-file>
# 输出：匹配的包文件名（不含 .sig），仅保留最新的 pkgver。
set -euo pipefail

PKG="${1:?package name required}"
FAMILY="${2:-$PKG}"
ASSET_NAMES="${3:?asset names file required}"

if [ ! -f "$ASSET_NAMES" ]; then
    echo "asset names file not found: $ASSET_NAMES" >&2
    exit 1
fi

escape_regex() {
    printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'
}

declare -a names=()
IFS=',' read -r -a declared <<< "$FAMILY"
for name in "${declared[@]}"; do
    [ -n "$name" ] || continue
    names+=("$name")
done
# pkgname 输出可能为空（PKGBUILD source 失败等）；当前包必须参与匹配。
found_pkg=0
for name in "${names[@]}"; do
    [ "$name" = "$PKG" ] && found_pkg=1
done
[ "$found_pkg" -eq 1 ] || names+=("$PKG")

regex=""
for name in "${names[@]}"; do
    esc="$(escape_regex "$name")"
    regex="${regex:+$regex|}^${esc}(-debug)?-[^-]+-[^-]+-[^-]+\.pkg\.tar\.zst$"
done

candidates="$(grep -E -- "$regex" "$ASSET_NAMES" | sort -u || true)"
[ -n "$candidates" ] || exit 0

# 中断的发布可能同时留下新旧两个版本：只取最新 pkgver。
maxver="$(printf '%s\n' "$candidates" \
    | sed -E 's/-[^-]+-[^-]+\.pkg\.tar\.zst$//' \
    | awk -F- '{print $NF}' | sort -V | tail -1)"
escver="$(escape_regex "$maxver")"
printf '%s\n' "$candidates" \
    | grep -E -- "-${escver}-[^-]+-[^-]+\.pkg\.tar\.zst$" \
    | sort -V
