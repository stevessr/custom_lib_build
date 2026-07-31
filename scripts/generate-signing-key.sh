#!/bin/bash
#
# generate-signing-key.sh — 一键生成仓库签名密钥并自动配置
#
# 功能：
#   1. 生成无口令 GPG 密钥对（RSA 4096，仅用于仓库签名）
#   2. 自动用 GitHub CLI 添加 Secret:  GPG_PRIVATE_KEY
#   3. 用生成的公钥替换仓库根目录的 arch_lib.pub.asc 并自动提交推送
#
# 前提：
#   - 已在仓库目录内（或 -R 指定仓库）
#   - 已安装 gh 且已登录（gh auth login），对仓库有 contents + secrets 权限
#
# 用法：
#   bash scripts/generate-signing-key.sh
#   # 可选：指定仓库
#   bash scripts/generate-signing-key.sh owner/repo
#
# 安全：生成的无口令私钥只会写入 GitHub Secret，本地不留存副本。
#
set -euo pipefail

REPO="${1:-}"
KEYEMAIL="arch-lib@localhost"
KEYREAL="arch_lib Repository Signing Key"
FPR=""

# ── 生成密钥 ────────────────────────────────────────────────────────
echo "=== 1/3 生成 GPG 密钥（无口令，RSA 4096） ==="
gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Name-Real: ${KEYREAL}
Name-Email: ${KEYEMAIL}
Expire-Date: 0
%commit
EOF

FPR=$(gpg --list-secret-keys --with-colons "$KEYEMAIL" | awk -F: '/^fpr/{print $10; exit}')
echo "密钥指纹: ${FPR}"

# ── 自动添加 Secret ─────────────────────────────────────────────────
echo ""
echo "=== 2/3 添加 GitHub Secret: GPG_PRIVATE_KEY ==="
if ! command -v gh &>/dev/null; then
    echo "✗ 未安装 GitHub CLI (gh)。请手动添加 Secret:"
    gpg --batch --armor --export-secret-keys "$FPR"
    exit 1
fi

if ! gh auth status &>/dev/null 2>&1; then
    echo "✗ 未登录 gh。请先运行: gh auth login"
    exit 1
fi

GHARGS=()
[ -n "$REPO" ] && GHARGS+=(-R "$REPO")

# 从文件读入私钥写入 Secret（不传 --body，自动从 stdin 读取）
gpg --batch --armor --export-secret-keys "$FPR" | gh secret set GPG_PRIVATE_KEY "${GHARGS[@]}"
echo "✔ Secret 已添加: GPG_PRIVATE_KEY"

# ── 提交公钥 ────────────────────────────────────────────────────────
echo ""
echo "=== 3/3 提交公钥 arch_lib.pub.asc ==="
gpg --batch --armor --export "$FPR" > arch_lib.pub.asc

git add arch_lib.pub.asc
git commit -m "chore: add repository signing public key" 2>/dev/null \
    && git push "${GHARGS[@]}" 2>/dev/null \
    || echo "（提交/推送失败，请手动 git add/commit/push）"
echo "✔ 公钥已提交"

# 清理：本地不保留私钥副本（Secret 已安全存储）
rm -f gpg-private-key.asc

# ── 导入 pacman 密钥环 ─────────────────────────────────────────────
echo ""
echo "=== 4/4 导入 pacman 密钥环 ==="
if command -v pacman-key &>/dev/null; then
    # pacman 用独立密钥环 /etc/pacman.d/gnupg，与用户级 gpg 钥匙圈无关。
    # 自生成密钥从未上传 keyserver，pacman 远程查找必然失败，
    # 必须在本地导入并本地签名信任。
    sudo pacman-key --add arch_lib.pub.asc
    yes | sudo pacman-key --lsign-key "$FPR"
    echo "✔ 公钥已导入 pacman 密钥环并本地信任"
    echo "  密钥指纹: ${FPR}"
    echo "  /etc/pacman.conf 可配置 SigLevel = Required DatabaseOptional"
else
    echo "⚠ 未检测到 pacman-key（非 Arch 系统？）。用户需在 Arch 上手动导入:"
    echo "    sudo pacman-key --add arch_lib.pub.asc"
    echo "    sudo pacman-key --lsign-key ${FPR}"
fi

echo ""
echo "=== 完成 ==="
echo "  Secret : GPG_PRIVATE_KEY（已配置）"
echo "  公钥   : arch_lib.pub.asc（已提交）"
echo "  pacman : 已导入本地密钥环并信任"
echo ""
echo "下次构建会自动签名包和数据库。"
