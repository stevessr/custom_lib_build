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
# 与上次发布的 version-<pkg>.txt 相同 → 无需构建（needs_build=false），
# 由 build-package.yaml 的 reuse job 复用旧包文件。
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
    printf 'needs_build=%s\nversion=%s\n' "$1" "$2" > "$OUT"
    echo "  check-version($PKG): needs_build=$1 version=$2"
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

# ── 5. 与上次发布版本对比 ───────────────────────────────────────────
prev=""
if [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    prev=$(curl -fsSL --max-time 20 --retry 3 --retry-all-errors --retry-delay 2 \
        -H "Authorization: Bearer $GH_TOKEN" \
        "https://github.com/$GITHUB_REPOSITORY/releases/download/latest/version-$PKG.txt" \
        2>/dev/null | tr -d '[:space:]' || true)
fi

if [ -n "$prev" ] && [ "$ver" = "$prev" ]; then
    write_result false "$ver"
else
    write_result true "$ver"
fi
