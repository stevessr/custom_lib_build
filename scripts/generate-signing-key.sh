#!/bin/bash
#
# generate-signing-key.sh — 一次性生成仓库签名密钥（本地运行）
#
# 用法：
#   1. 在本仓库根目录运行:  bash scripts/generate-signing-key.sh
#   2. 把 gpg-private-key.asc 内容添加到 GitHub Secret:  GPG_PRIVATE_KEY
#   3. 把 arch_lib.pub.asc 提交到仓库（供用户导入）
#   4. 删除本地 gpg-private-key.asc（私钥只应存在于 GitHub Secret）
#
# 生成的是无口令密钥（CI 无法交互输入口令），仅用于仓库签名。
# 不要用于其他任何用途。
#
set -euo pipefail

KEYEMAIL="arch-lib@localhost"
KEYREAL="arch_lib Repository Signing Key"

echo "=== 生成 GPG 密钥（无口令，RSA 4096） ==="
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
echo ""
echo "=== 密钥指纹: ${FPR} ==="

# 私钥 → GitHub Secret（GPG_PRIVATE_KEY）
gpg --batch --armor --export-secret-keys "$FPR" > gpg-private-key.asc
echo ""
echo "✔ 私钥已保存:  gpg-private-key.asc"
echo "  下一步: 把该文件内容添加到 GitHub → Settings → Secrets → Actions"
echo "  Secret 名称:  GPG_PRIVATE_KEY"

# 公钥 → 提交到仓库
gpg --batch --armor --export "$FPR" > arch_lib.pub.asc
echo "✔ 公钥已保存:  arch_lib.pub.asc"
echo "  下一步: 提交此文件到仓库根目录"

echo ""
echo "⚠ 安全提醒: 确认 Secret 配置好后删除本地私钥文件"
echo "  rm gpg-private-key.asc"
