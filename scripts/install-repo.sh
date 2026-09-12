#!/usr/bin/env bash
#
# install-repo.sh — 一键配置 arch_lib pacman 仓库
#
# 用法：
#   curl -fsSL --proto '=https' --tlsv1.2 \
#     https://raw.githubusercontent.com/stevssr/custom_lib_build/master/scripts/install-repo.sh \
#     | bash
#
# 脚本只配置仓库和导入签名密钥，不会自动安装软件包或执行系统升级。
#
set -euo pipefail

readonly REPO_NAME='arch_lib'
readonly DEFAULT_REPO_URL='https://github.com/stevssr/custom_lib_build/releases/download/latest'
readonly EXPECTED_FINGERPRINT='083606DCE3EF558F3B07166F7E9C676EC5211963'
readonly BEGIN_MARKER='# >>> arch_lib repository (managed by install-repo.sh) >>>'
readonly END_MARKER='# <<< arch_lib repository (managed by install-repo.sh) <<<'

REPO_URL="$DEFAULT_REPO_URL"
PACMAN_CONF='/etc/pacman.conf'
DRY_RUN=0
KEY_FILE=''
TEMP_DIR=''
STAGED_CONFIG=''

usage() {
    cat <<'EOF'
用法：install-repo.sh [选项]

将 arch_lib 仓库加入 /etc/pacman.conf，并导入仓库签名公钥。

选项：
  --repo-url URL  覆盖仓库地址（必须是 HTTPS URL）
  --config FILE   覆盖 pacman 配置文件（主要用于测试）
  --dry-run       下载并校验公钥，但不修改密钥环或配置文件
  -h, --help      显示帮助

默认仓库：
  https://github.com/stevssr/custom_lib_build/releases/download/latest
EOF
}

fail() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$STAGED_CONFIG" && -e "$STAGED_CONFIG" ]]; then
        root_cmd rm -f -- "$STAGED_CONFIG" 2>/dev/null || true
    fi
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
trap cleanup EXIT

root_cmd() {
    if (( EUID == 0 )); then
        command "$@"
    else
        sudo "$@"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "缺少依赖：$1"
}

validate_repo_url() {
    [[ "$REPO_URL" == https://* ]] || fail '--repo-url 只能使用 HTTPS URL'
    [[ "$REPO_URL" != *[[:space:]]* ]] || fail '--repo-url 不能包含空白字符'
    [[ "$REPO_URL" != *['#?']* ]] || fail '--repo-url 不能包含查询参数或片段'
    REPO_URL="${REPO_URL%/}"
    [[ "$REPO_URL" != 'https:' ]] || fail '仓库 URL 不能为空'
}

while (($# > 0)); do
    case "$1" in
        --repo-url)
            (($# >= 2)) || fail '--repo-url 需要一个参数'
            REPO_URL="$2"
            shift 2
            ;;
        --config)
            (($# >= 2)) || fail '--config 需要一个参数'
            PACMAN_CONF="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "未知参数：$1（使用 --help 查看帮助）"
            ;;
    esac
done

validate_repo_url
[[ "$PACMAN_CONF" == /* ]] || fail '--config 必须是绝对路径'
[[ -f /etc/arch-release ]] || fail '此脚本只支持 Arch Linux'

require_command curl
require_command gpg
require_command pacman
require_command pacman-conf
[[ -f "$PACMAN_CONF" ]] || fail "找不到 pacman 配置文件：$PACMAN_CONF"
[[ ! -L "$PACMAN_CONF" ]] || fail "拒绝修改符号链接形式的配置文件：$PACMAN_CONF"

if (( ! DRY_RUN )); then
    require_command pacman-key
    if (( EUID != 0 )); then
        require_command sudo
    fi
fi

TEMP_DIR="$(mktemp -d)"
umask 077
KEY_FILE="$TEMP_DIR/arch_lib.pub.asc"
KEY_URL="${REPO_URL}/arch_lib.pub.asc"

# 当前 latest Release 可能尚未上传公钥；默认仓库可安全回退到源码中的同一公钥。
# 自定义镜像不回退到默认仓库，避免把不同仓库的密钥错误地绑定在一起。
download_key() {
    printf '下载并校验仓库公钥：%s\n' "$KEY_URL"
    if curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 --retry 3 --retry-all-errors --retry-delay 2 \
        --connect-timeout 10 --max-time 60 \
        --output "$KEY_FILE" "$KEY_URL"; then
        return 0
    fi

    if [[ "$REPO_URL" != "$DEFAULT_REPO_URL" ]]; then
        return 1
    fi

    KEY_URL='https://raw.githubusercontent.com/stevssr/custom_lib_build/master/arch_lib.pub.asc'
    printf 'Release 中没有公钥，回退到源码：%s\n' "$KEY_URL"
    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 --retry 3 --retry-all-errors --retry-delay 2 \
        --connect-timeout 10 --max-time 60 \
        --output "$KEY_FILE" "$KEY_URL"
}

if ! download_key; then
    if [[ "$REPO_URL" != "$DEFAULT_REPO_URL" ]]; then
        fail '无法下载仓库公钥'
    fi
    # Release/raw 均不可用时，使用与 EXPECTED_FINGERPRINT 同步的内置公钥。
    # 这样 latest 尚未发布公钥资产时，首次配置仍可完成；密钥轮换时必须同步更新本脚本。
    printf '远程公钥不可用，使用脚本内置公钥。\n'
    cat > "$KEY_FILE" <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBGpsD14BEADAa1Mrro3KBBKkGw5fXNrwC6mWiIclS/ZGqjyUWG469CksbzHN
Vs5pKIWXf44kx/8L2dd4nR3NX2a3T620rK6VWJxmgHOUYz4sH07O/1+uZbnWUIUK
aUgmj3D2JID63QIhleSN9TDdA04CA5RBtpSz/jE1J1QIq38jVvrV3s5oP1WzaHMS
3ywS6mhbUYDb+m4oer6DWGBXuquFHRfjqAIHqeREBXAV5QKyHRWCDUIAoTW1H84K
/SVWJncvz5i4dDkPTxwzZCiZuYmdwYF1k0fNpwCueSRYnyxAX54IfhaFEhAGCj2G
ttmCFrIFRNeDT2IUCkjG0pgQ5ymLSz4CBMXNbwPTBvCoVYisNz4hUbFgWK4NiDt8
PiGYxxCzoXPrgPnmeYWMsipXezPADtM2jTcIpIOkIdBP/xBxllRLsxLOwxcMNY5e
Pr8hjUn8k4mZoyFTYMIq7342JU6z5mHhw3yn90ZAklGo1E22mAsOhj+wu+ddqY7c
cBrv50blLCYDxqVSuEI31wNYJtjepRBIw66dHWaZcUBD5NzhGnLe4TYRX5HnZoEy
wjRhkATGDydmRQRHLcAkasyvVEcox9hSTKzE9h3jCt0M3ZDT/U6JrnaoMu9X/2fa
otnbUOUgRL4aEBioFB1/JhVCfIVxQhrktMnfFzCbGdEYzZ5OHFCI20Zc0wARAQAB
tDRhcmNoX2xpYiBSZXBvc2l0b3J5IFNpZ25pbmcgS2V5IDxhcmNoLWxpYkBsb2Nh
bGhvc3Q+iQJPBBMBCgA5FiEECDYG3OPvVY87BxZvfpxnbsUhGWMFAmpsD14DGy8E
BQsJCAcCBhUKCQgLAgQWAgMBAh4BAheAAAoJEH6cZ27FIRljUAEQAIgPJka7qZ4g
MuOnBOGHyEcTmn4VvxTC0c+sMm/YyNC4OgbAqrrI8dMGbj/SKKqsoa+3lF3+FjeI
EIY36uqR/h4ybEG/Tg4HYyclu6pjY3FL/obhcZVoGCk6+uJXo/ZuJ8+YMHcwldF9
s+Cl9ZoPfy7W+r36YKvK84gFD/RXp3VLx+9Hv5y7v0XNtrPa4rEXljxCxwzm7kkW
7IdQd8MXi6jvAcRuzr5UgkD7cVjC6ztq9ObgQhnxwB/HAf0jbeAXFD3LNOP5Qx5b
AgqUIzPqNezgXtcNybftOZd/J2euab+HNt0uXzm2ApWY8Cv0mOXabl7Z78FxHmh4
4fqtb9m2dMF+UiQjp/i5u8Kb0KBMTq1N3JKFNKcTSybUJATp6gKxEka/I1jKg25d
kgh8VLs/PN+MwZLLjwESIl3fWvQwAHcqaJ0kfCXFCCPCmNJYziz3m1nSbauwt7KN
AiNm4EaRn4j8TzsScn46X3ck8BYtGaibzGbXCIMJbZwQq/GpM4fCHLoz3MiYedfv
7SIL76ZJ848kV4+QRXGKELN1iUGNm1KakCKXY82X1igs3Atcqu7K3z/yIXm6OAk0
VOkShm+PUGhjlg2EVQwNZ7t59e9Ym9D6hA2Ap6WHbetbKqmjgDmTIbTF1JdePDEN
ehGjEvk/sEKdT3KCAGuKZr5MwTPcZd4T
=y+RA
-----END PGP PUBLIC KEY BLOCK-----
EOF
fi

fingerprint="$(gpg --batch --with-colons --show-keys "$KEY_FILE" 2>/dev/null \
    | awk -F: '$1 == "fpr" { print toupper($10); exit }')"
[[ -n "$fingerprint" ]] || fail '下载的文件不是有效的 OpenPGP 公钥'
[[ "$fingerprint" == "$EXPECTED_FINGERPRINT" ]] || fail \
    "公钥指纹不匹配（收到：$fingerprint，期望：$EXPECTED_FINGERPRINT）"
printf '公钥指纹已验证：%s\n' "$fingerprint"

# 先在临时文件中移除本脚本上次写入的配置块，并检查是否有未托管的同名仓库。
BASE_CONFIG="$TEMP_DIR/pacman.conf.base"
if ! awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin {
        if (inside) exit 2
        inside = 1
        next
    }
    $0 == end {
        if (!inside) exit 3
        inside = 0
        next
    }
    !inside { print }
    END {
        if (inside) exit 4
    }
' "$PACMAN_CONF" > "$BASE_CONFIG"; then
    fail "配置文件中的 arch_lib 管理标记不完整或重复：$PACMAN_CONF"
fi

if grep -Eq "^[[:space:]]*\[$REPO_NAME\][[:space:]]*$" "$BASE_CONFIG"; then
    fail "配置文件已包含未由本脚本管理的 [$REPO_NAME] 段，请先手动处理后重试"
fi

NEW_CONFIG="$TEMP_DIR/pacman.conf.new"
cat "$BASE_CONFIG" > "$NEW_CONFIG"
printf '\n%s\n[%s]\nSigLevel = Optional DatabaseOptional\nServer = %s\n%s\n' \
    "$BEGIN_MARKER" "$REPO_NAME" "$REPO_URL" "$END_MARKER" >> "$NEW_CONFIG"

if ! pacman-conf --config "$NEW_CONFIG" --repo "$REPO_NAME" Server >/dev/null; then
    fail '生成的 pacman 配置无法通过 pacman-conf 校验'
fi

if (( DRY_RUN )); then
    printf '\n[预览] 将在 %s 末尾写入：\n' "$PACMAN_CONF"
    sed -n "/$(printf '%s' "$BEGIN_MARKER" | sed 's/[][\.^$*\\/]/\\&/g')/,\$p" "$NEW_CONFIG"
    printf '\n预览模式未修改密钥环或 pacman 配置。\n'
    exit 0
fi

printf '导入并信任仓库签名密钥……\n'
root_cmd pacman-key --add "$KEY_FILE" >/dev/null
printf 'y\n' | root_cmd pacman-key --lsign-key "$EXPECTED_FINGERPRINT" >/dev/null

# 保留原配置权限，并在同一目录中用 mv 原子替换，避免 pacman 读到半写文件。
config_mode="$(stat -c '%a' "$PACMAN_CONF")"
config_owner="$(stat -c '%u:%g' "$PACMAN_CONF")"
backup_file="${PACMAN_CONF}.bak.$(date -u +%Y%m%d%H%M%S)-$$"
root_cmd cp -p -- "$PACMAN_CONF" "$backup_file"
STAGED_CONFIG="$(root_cmd mktemp "${PACMAN_CONF}.arch_lib.tmp.XXXXXX")"
root_cmd install -m "$config_mode" -- "$NEW_CONFIG" "$STAGED_CONFIG"
root_cmd chown "$config_owner" "$STAGED_CONFIG"
root_cmd mv -f -- "$STAGED_CONFIG" "$PACMAN_CONF"
STAGED_CONFIG=''

printf '\n✔ arch_lib 仓库已添加。\n'
printf '配置文件：%s\n' "$PACMAN_CONF"
printf '备份文件：%s\n' "$backup_file"
printf '\n现在可以运行：\n'
printf '  sudo pacman -Syu\n'
printf '  sudo pacman -S claude-desktop-http-patch  # 方案 2（与 full 二选一）\n'
printf '  sudo pacman -S claude-desktop-full-patch  # 方案 3（与 http 二选一）\n'
printf '\nClaude patch 包会通过 /etc/claude-desktop/managed-settings.json 禁用官方自动更新。\n'
printf '若系统已有官方 .deb 或手工安装，请先卸载/停用，避免它覆盖打过补丁的 app.asar。\n'
