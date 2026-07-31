#!/bin/bash
#
# import-signing-key.sh — 一键导入 arch_lib 仓库签名公钥到 pacman 密钥环
#
# 为什么需要这个脚本：
#   arch_lib 的签名密钥是自生成的（从未上传 keyserver），
#   pacman 远程查找必然失败。必须在本地导入公钥并本地签名信任。
#
# 用法：
#   bash scripts/import-signing-key.sh [owner/repo]
#   # 默认从当前 git remote 推断仓库；也可显式指定
#   bash scripts/import-signing-key.sh stevessr/custom_lib_build
#
# 等价的手动命令：
#   sudo pacman-key --add arch_lib.pub.asc
#   sudo pacman-key --lsign-key <指纹>
#
set -euo pipefail

# ── 确定仓库 ────────────────────────────────────────────────────────
REPO="${1:-}"
if [ -z "$REPO" ]; then
    REMOTE=$(git remote get-url origin 2>/dev/null || true)
    REPO=$(echo "$REMOTE" | sed -E 's#.*github\.com[:/]##; s#\.git$##' 2>/dev/null || true)
fi
if [ -z "$REPO" ]; then
    echo "✗ 无法推断仓库。请显式指定:  bash scripts/import-signing-key.sh owner/repo"
    exit 1
fi
echo "仓库: $REPO"

# ── 下载公钥（优先 Release，回退源码） ─────────────────────────────
TMP_KEY="/tmp/arch_lib.pub.asc"
DL_URL="https://github.com/${REPO}/releases/download/latest/arch_lib.pub.asc"
echo "下载公钥: $DL_URL"

if ! curl -fsSL "$DL_URL" -o "$TMP_KEY"; then
    echo "  Release 中无公钥，回退到源码..."
    curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/arch_lib.pub.asc" -o "$TMP_KEY"
fi

# 校验是有效 PGP 公钥
if ! gpg --with-colons --show-keys "$TMP_KEY" >/dev/null 2>&1; then
    echo "✗ 下载的文件不是有效 GPG 公钥。仓库可能尚未配置签名。"
    echo "  请先让仓库所有者运行:  bash scripts/generate-signing-key.sh"
    exit 1
fi

# ── 导入 pacman 密钥环 ─────────────────────────────────────────────
FPR=$(gpg --with-colons --show-keys "$TMP_KEY" | awk -F: '/^fpr/{print $10; exit}')
echo ""
echo "公钥指纹: ${FPR}"
echo "导入到 pacman 密钥环 (/etc/pacman.d/gnupg) ..."

sudo pacman-key --add "$TMP_KEY"
yes | sudo pacman-key --lsign-key "$FPR"

rm -f "$TMP_KEY"

echo ""
echo "✔ 完成！公钥已导入并本地信任。"
echo ""
echo "现在可在 /etc/pacman.conf 使用严格签名："
echo ""
echo "  [arch_lib]"
echo "  SigLevel = Required DatabaseOptional"
echo "  Server = https://github.com/${REPO}/releases/download/latest"
echo ""
echo "然后:  sudo pacman -Sy"
