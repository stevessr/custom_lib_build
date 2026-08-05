#!/bin/bash
#
# publish-release.sh — 增量更新 `latest` Release（替换"删除后全量重建"）
#
# 优化点：
#   1. 版本未变化的包文件原样保留在 latest，不重复上传
#      （此前每次发布都删除全部 ~110 资产再上传 ~7.5GB）
#   2. 不删除 release/tag——只增删资产，消除 pacman 用户的 404 窗口期
#   3. 全部包版本未变化且资产齐全时，完全不触碰 release
#   4. 顺序保证：先传新包文件 + 配套 .sig → 删除旧版本资产 → 最后
#      重建 db 资产，pacman 用户始终能拿到一致状态
#   5. 包文件的 .sig 必须与包文件同批上传：repo-add 入库时引用的是
#      当前构建的 .sig，若只重传包文件而保留 release 上旧的 .sig，
#      pacman 会报 BADSIG（custom 包每次重建字节不同，旧 .sig 必然
#      失配）。
#
# 版本判定（与 check-version.sh 的 version 文件对比）：
#   - 版本变化的包：其所有包文件强制"删同名 + 重传"（custom 包如
#     sparkle-bin 每次重建但文件名不变，必须重传；重跑场景同名资产
#     可能是旧构建产物，也必须重传保证与 db 的 sha256 匹配）
#   - 版本未变的包：资产已在 latest（前置校验过），整体跳过
#
# 幂等：重跑时同名资产先删再传；失败后 rerun 安全。
#
# Usage:
#   publish-release.sh <repo-dir> <metadata-dir> <pubkey> <token>
#     repo-dir     repos/x86_64（包文件 + db + 签名）
#     metadata-dir 收集的 version-*.txt / manifest-*.txt
#     pubkey       arch_lib.pub.asc 路径
#     token        GITHUB_TOKEN
#
set -euo pipefail

REPO_DIR="$1"
META_DIR="$2"
PUBKEY="$3"
TOKEN="$4"

API="https://api.github.com/repos/$GITHUB_REPOSITORY"
UPLOAD="https://uploads.github.com/repos/$GITHUB_REPOSITORY"
DOWNLOAD="https://github.com/$GITHUB_REPOSITORY/releases/download/latest"
# 测试时可覆盖基址（本地 mock 服务器）
API="${API_BASE:-https://api.github.com}/repos/$GITHUB_REPOSITORY"
UPLOAD="${UPLOAD_BASE:-https://uploads.github.com}/repos/$GITHUB_REPOSITORY"
DOWNLOAD="${DOWNLOAD_BASE:-https://github.com}/$GITHUB_REPOSITORY/releases/download/latest"
AUTH="Authorization: Bearer $TOKEN"
RELEASE_NAME="Arch Lib Repository $(date -u +%Y-%m-%d)"

echo "== publish-release: $GITHUB_REPOSITORY =="

# ── 1. 定位 latest release（不存在则创建）──────────────────────────
release_json=$(curl -fsSL -H "$AUTH" "$API/releases/tags/latest" 2>/dev/null || true)
if [ -z "$release_json" ]; then
    echo "No latest release found — creating"
    body=$(cat <<'EOF'
## arch_lib pacman repository

Daily build of AUR packages.

**Usage** — add to `/etc/pacman.conf`:
```ini
[arch_lib]
SigLevel = Optional TrustAll
Server = https://github.com/OWNER_REPO/releases/download/latest
```

Then: `sudo pacman -Sy && sudo pacman -S <package>`

**Signing**: 若已配置 GPG_PRIVATE_KEY，包和数据库均带 `.sig` 签名。
导入公钥后可改用 `SigLevel = Required DatabaseOptional` 验证。
EOF
    )
    body=${body//OWNER_REPO/$GITHUB_REPOSITORY}
    release_json=$(curl -fsSL -X POST -H "$AUTH" -H "Content-Type: application/json" \
        -d "$(jq -n --arg tag latest --arg name "$RELEASE_NAME" --arg body "$body" \
            '{tag_name:$tag, name:$name, body:$body}')" \
        "$API/releases")
fi
RELEASE_ID=$(printf '%s' "$release_json" | jq -r '.id')
echo "Release #$RELEASE_ID"

# ── 2. 现有资产清单（分页）─────────────────────────────────────────
declare -A ASSET_IDS=()
assets_json=$(mktemp)
: > "$assets_json"
page=1
while :; do
    chunk=$(curl -fsSL -H "$AUTH" "$API/releases/$RELEASE_ID/assets?per_page=100&page=$page")
    [ "$(printf '%s' "$chunk" | jq 'length')" -eq 0 ] && break
    printf '%s\n' "$chunk" >> "$assets_json"
    page=$((page + 1))
done
while IFS=$'\t' read -r id name; do
    [ -n "$name" ] && ASSET_IDS["$name"]="$id"
done < <(jq -r '.[] | [.id, .name] | @tsv' "$assets_json")
rm -f "$assets_json"
echo "Existing assets: ${#ASSET_IDS[@]}"

# ── 3. 版本对比：找出变化的包；资产齐全性校验 ──────────────────────
declare -A CHANGED_PKGS=()
need_publish=0
for vf in "$META_DIR"/version-*.txt; do
    [ -f "$vf" ] || continue
    pkg=$(basename "$vf" | sed 's/^version-//; s/\.txt$//')
    old=$(curl -fsSL --max-time 20 -H "$AUTH" "$DOWNLOAD/$(basename "$vf")" 2>/dev/null | tr -d '[:space:]' || true)
    new=$(tr -d '[:space:]' < "$vf")
    if [ "$old" != "$new" ]; then
        echo "  changed: $pkg ($new) vs published (${old:-none})"
        CHANGED_PKGS["$pkg"]=1
        need_publish=1
    fi
    # 包文件资产必须存在（版本未变的包）；.sig 缺失也要补齐
    mf_name="manifest-${pkg}.txt"
    if [ -f "$META_DIR/$mf_name" ]; then
        while IFS= read -r pf; do
            [ -n "$pf" ] || continue
            if [ -z "${ASSET_IDS[$pf]:-}" ]; then
                echo "  missing asset: $pf"
                need_publish=1
            fi
            if [ -f "$REPO_DIR/$pf.sig" ] && [ -z "${ASSET_IDS[$pf.sig]:-}" ]; then
                echo "  missing .sig asset: $pf.sig"
                need_publish=1
            fi
        done < "$META_DIR/$mf_name"
    fi
done
# db 资产必须存在（上次发布可能失败在 db 重建前）
for db in arch_lib.db arch_lib.db.tar.gz arch_lib.files arch_lib.files.tar.gz; do
    if [ -z "${ASSET_IDS[$db]:-}" ]; then
        echo "  missing db asset: $db"
        need_publish=1
    fi
done

if [ "$need_publish" -eq 0 ]; then
    echo "== All package versions unchanged and assets complete — release untouched =="
    exit 0
fi

# ── 4. 上传/删除辅助（先删同名再传 = 幂等）─────────────────────────
delete_asset() { # <name>
    local name="$1"
    if [ -n "${ASSET_IDS[$name]:-}" ]; then
        curl -fsSL -X DELETE -H "$AUTH" "$API/releases/assets/${ASSET_IDS[$name]}" -o /dev/null \
            && echo "  deleted: $name" || echo "  ⚠ delete failed (ignore): $name"
        unset 'ASSET_IDS[$name]'
    fi
}

upload_asset() { # <name> <file>
    local name="$1" file="$2"
    local encoded
    encoded=$(jq -rn --arg v "$name" '$v|@uri')
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 \
        -X POST -H "$AUTH" -H "Content-Type: application/octet-stream" \
        --data-binary @"$file" "$UPLOAD/releases/$RELEASE_ID/assets?name=$encoded" \
        -o /dev/null && echo "  uploaded: $name"
}
export -f upload_asset
export TOKEN RELEASE_ID UPLOAD AUTH

# ── 5. 逐包：版本变化的包强制重传全部新文件 + 清理旧文件 ───────────
for mf in "$META_DIR"/manifest-*.txt; do
    [ -f "$mf" ] || continue
    pkg=$(basename "$mf" | sed 's/^manifest-//; s/\.txt$//')
    if [ -z "${CHANGED_PKGS[$pkg]:-}" ]; then
        echo "-- package: $pkg (unchanged, kept on release)"
        continue
    fi
    echo "-- package: $pkg (changed — re-uploading)"

    # 新文件名列表
    new_files=()
    while IFS= read -r pf; do
        [ -n "$pf" ] && new_files+=("$pf")
    done < "$mf"

    # 旧文件名列表（latest 上的 manifest，可能不存在）
    old_files=()
    old_mf=$(curl -fsSL --max-time 20 -H "$AUTH" "$DOWNLOAD/manifest-$pkg.txt" 2>/dev/null || true)
    if [ -n "$old_mf" ]; then
        while IFS= read -r pf; do
            [ -n "$pf" ] && old_files+=("$pf")
        done <<< "$old_mf"
    fi

    # 删除同名旧资产 → 并发上传新文件 + 配套 .sig（子进程仅依赖已 export 的环境）
    # 必须与包文件同批处理 .sig：repo-add 的 db 引用的是当前构建的 .sig，
    # 若只重传包文件而保留 release 上旧的 .sig，pacman 校验会报 BADSIG
    # （custom 包每次重建字节不同——.PKGINFO builddate 变化——旧 .sig 必然失配）。
    to_upload=()
    for pf in "${new_files[@]}"; do
        [ -f "$REPO_DIR/$pf" ] || { echo "  ✗ missing file: $REPO_DIR/$pf"; exit 1; }
        delete_asset "$pf"
        to_upload+=("$REPO_DIR/$pf")
        if [ -f "$REPO_DIR/$pf.sig" ]; then
            delete_asset "$pf.sig"
            to_upload+=("$REPO_DIR/$pf.sig")
        else
            # 本次构建未签名：清掉 release 上的旧 .sig，避免 pacman
            # 用旧签名校验新文件（BADSIG）
            delete_asset "$pf.sig"
        fi
    done
    if [ "${#to_upload[@]}" -gt 0 ]; then
        printf '%s\n' "${to_upload[@]}" | xargs -P 6 -I{} bash -c 'upload_asset "$(basename "{}")" "{}"'
    fi

    # 旧版本文件清理（不在新清单中）
    for pf in "${old_files[@]}"; do
        keep=0
        for nf in "${new_files[@]}"; do
            [ "$pf" = "$nf" ] && keep=1
        done
        [ "$keep" -eq 1 ] && continue
        delete_asset "$pf"
        delete_asset "$pf.sig"
    done
done

# ── 5b. 补齐缺失的 .sig（版本未变的包也可能缺：早期脚本只传包文件）─
for mf in "$META_DIR"/manifest-*.txt; do
    [ -f "$mf" ] || continue
    pkg=$(basename "$mf" | sed 's/^manifest-//; s/\.txt$//')
    # step 5 已处理 changed 包的 .sig，无需重复
    [ -z "${CHANGED_PKGS[$pkg]:-}" ] || continue
    while IFS= read -r pf; do
        [ -n "$pf" ] || continue
        [ -f "$REPO_DIR/$pf.sig" ] || continue
        if [ -z "${ASSET_IDS[$pf.sig]:-}" ]; then
            echo "  backfilling .sig: $pf.sig"
            upload_asset "$pf.sig" "$REPO_DIR/$pf.sig"
        fi
    done < "$mf"
done

# ── 6. 元数据（version/manifest，小文件，同名覆盖）──────────────────
for mf in "$META_DIR"/*.txt; do
    [ -f "$mf" ] || continue
    name=$(basename "$mf")
    delete_asset "$name"
    upload_asset "$name" "$mf"
done

# ── 7. 公钥（存在且未上传过则上传）─────────────────────────────────
if [ -f "$PUBKEY" ] && [ -z "${ASSET_IDS[arch_lib.pub.asc]:-}" ]; then
    upload_asset arch_lib.pub.asc "$PUBKEY"
fi

# ── 8. 最后重建 db 资产（新包文件全部就位后，pacman 指向才有效）────
for db in arch_lib.db arch_lib.db.sig arch_lib.db.tar.gz arch_lib.db.tar.gz.sig \
          arch_lib.files arch_lib.files.sig arch_lib.files.tar.gz arch_lib.files.tar.gz.sig; do
    [ -f "$REPO_DIR/$db" ] || continue
    delete_asset "$db"
    upload_asset "$db" "$REPO_DIR/$db"
done

# ── 9. 更新 release 名称/说明（不删除 release 对象）─────────────────
curl -fsSL -X PATCH -H "$AUTH" -H "Content-Type: application/json" \
    -d "$(jq -n --arg name "$RELEASE_NAME" '{name:$name}')" \
    "$API/releases/$RELEASE_ID" -o /dev/null

echo "== latest release #$RELEASE_ID updated =="
