#!/bin/bash
#
# check-version.sh — 在重流程（容器启动 / pacman 升级 / 源码构建）之前
# 判断某个包是否需要重建。
#
# 版本判定语义与 build-package.sh 保持一致（同一仓库内两处必须同步）：
#   - custom-pkgs/<pkg>/ 存在     → 总是重建（current_ver=custom）
#   - <pkg>-git 包                → 取 source=() 第一个 git+ URL 的
#                                   HEAD commit（git ls-remote）
#   - 普通 AUR 包                 → PKGBUILD 静态 pkgver
#
# 判定规则（普通包，自愈式）：
#   1. version-<pkg>.txt == 当前 pkgver → 无需构建（快路径）
#   2. 不一致时 HEAD 探测 latest 上是否已存在
#      <pkg>-<epoch:>pkgver-pkgrel-<arch>.pkg.tar.zst（epoch 冒号与
#      资产存储名一致地转成 '_'）：存在 → 复用（publish 中断留下的
#      “包文件已传、version 元数据未更新”中间态无需白白重建一次）；
#      不存在 → 构建。
#   - -git 包仍只对比 version 文件中的 commit hash（文件名不含完整 hash）
#
# 由 build-package.yaml 的 reuse job 复用旧包文件时，会顺带把
# version-<pkg>.txt 刷新为本次计算出的版本，中间态因此自愈。
#
# 任何网络/解析失败都保守地输出 needs_build=true（宁可多构建一次，
# 也不能让包从仓库消失）；脚本整体失败（set -e）时 check job 失败，
# 上游 build job 以 failure() 兜底照常构建。
#
# Usage:
#   check-version.sh <pkg> <workspace> <output-file>
# Output file:
#   needs_build=true|false
#   version=<pkgver|commit|custom|unknown>
#
set -euo pipefail

PKG="$1"
WS="${2:-$GITHUB_WORKSPACE}"
OUT="${3:-$WS/check-$PKG.env}"

write_result() {
    printf 'needs_build=%s\nversion=%s\npkgname=%s\n' "$1" "$2" "${pkglist:-}" > "$OUT"
    echo "  check-version($PKG): needs_build=$1 version=$2 pkgname=${pkglist:-}"
}

# ── 1. Custom PKGBUILD → 总是重建 ──────────────────────────────────
if [ -f "$WS/custom-pkgs/$PKG/PKGBUILD" ]; then
    write_result true custom
    exit 0
fi

# ── 2. 定位 AUR PackageBase（split 包如 rustrover-jre → rustrover）──
base="$PKG"
for attempt in 1 2 3; do
    base=$(curl -fsSL --max-time 10 \
        "https://aur.archlinux.org/rpc/v5/info?arg[]=$PKG" \
        | jq -r '.results[0].PackageBase // empty' 2>/dev/null || true)
    [ -n "$base" ] && break
    echo "  (AUR RPC attempt $attempt failed; retrying)"
    sleep 3
done
[ -n "$base" ] || base="$PKG"

# ── 3. 下载 PKGBUILD（cgit plain，单文件，比 clone 轻）─────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
if ! curl -fsSL --max-time 30 --retry 5 --retry-all-errors --retry-delay 3 \
    "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=$base" \
    -o "$TMP_DIR/PKGBUILD" 2>/dev/null; then
    echo "  ⚠ AUR PKGBUILD fetch failed for $PKG — conservative rebuild"
    write_result true unknown
    exit 0
fi

# ── 4. 计算当前版本（语义与 build-package.sh 相同）──────────────────
cd "$TMP_DIR"

# pkgname 列表（split 包同族，如 rustrover → rustrover,rustrover-jre）
# 供 reuse job 为同族包一并刷新 version 文件（共享同一 pkgver）
pkglist="$(bash -c 'source PKGBUILD 2>/dev/null; printf "%s\n" "${pkgname[@]}"' 2>/dev/null | paste -sd, - || true)"
rel="$(bash -c 'source PKGBUILD 2>/dev/null; echo "${pkgrel:-1}"')"
arch="$(bash -c 'source PKGBUILD 2>/dev/null; echo "${arch[0]:-x86_64}"')"
epoch="$(bash -c 'source PKGBUILD 2>/dev/null; echo "${epoch:-}"')"

if [[ "$PKG" == *-git ]]; then
    # -git: 第一个 git+ source URL 的 HEAD commit
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
        ver="$(bash -c 'source PKGBUILD; echo "${pkgver:-unknown}"')"
    else
        url="${first_git#git+}"
        url="${url%%#*}"
        branch=""
        case "$first_git" in
            *#branch=*) branch="${first_git##*#branch=}" ;;
        esac
        ref="HEAD"
        [ -n "$branch" ] && ref="refs/heads/$branch"
        ver="$(git ls-remote "$url" "$ref" 2>/dev/null | awk '{print $1}')" || ver=""
        if [ -z "$ver" ]; then
            echo "  ⚠ git ls-remote failed for $url — conservative rebuild"
            write_result true unknown
            exit 0
        fi
    fi
else
    # 普通包：静态 pkgver
    ver="$(bash -c 'source PKGBUILD; echo "${pkgver:-unknown}"')"
fi

# ── 5. 与上次发布状态对比 ───────────────────────────────────────────
prev=""
if [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    prev=$(curl -fsSL --max-time 20 --retry 3 --retry-all-errors --retry-delay 2 \
        -H "Authorization: Bearer $GH_TOKEN" \
        "https://github.com/$GITHUB_REPOSITORY/releases/download/latest/version-$PKG.txt" \
        2>/dev/null | tr -d '[:space:]' || true)
fi

if [ -n "$prev" ] && [ "$ver" = "$prev" ]; then
    write_result false "$ver"
    exit 0
fi

if [[ "$PKG" == *-git ]]; then
    # -git：version 文件不一致（或缺失）→ 重建
    write_result true "$ver"
    exit 0
fi

# 普通包：version 文件不一致时，HEAD 探测 latest 是否已存在当前
# pkgver-pkgrel 的包资产。publish 中断会留下“包文件已传、元数据未更”
# 的中间态；资产已在就直接复用（否则版本没变也每天重建一次），
# reuse job 随后会把 version 文件刷新为当前值。
filename="$PKG-${epoch:+$epoch:}$ver-$rel-$arch.pkg.tar.zst"
filename="${filename//:/_}"   # epoch 冒号与资产存储名一致（上传前已 sanitize）
enc=$(jq -rn --arg v "$filename" '$v|@uri')
code=""
if [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    code=$(curl -sIL --max-time 20 --retry 2 --retry-all-errors --retry-delay 2 \
        -H "Authorization: Bearer $GH_TOKEN" \
        "https://github.com/$GITHUB_REPOSITORY/releases/download/latest/$enc" \
        -o /dev/null -w '%{http_code}' 2>/dev/null || true)
fi

if [ "$code" = "200" ]; then
    echo "  asset already on latest ($filename) — reuse despite stale version file"
    write_result false "$ver"
else
    write_result true "$ver"
fi
