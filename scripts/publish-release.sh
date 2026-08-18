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
#   6. split 包共享同名文件（rustrover/rustrover-jre 的 manifest 都包含
#      rustrover-*.pkg.tar.zst）：本轮已上传成功的资产名全 run 去重，
#      避免对同名资产重复 delete+upload 触发 GitHub 422（asset already
#      exists）；上传返回的 asset id 同步回填 ASSET_IDS，防止后续同名
#      delete 因 map 过期而 no-op。
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
declare -A MISSING_FILES=() # 版本未变但资产缺失（上次发布中断遗留）
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
                MISSING_FILES["$pf"]=1
            fi
            if [ -f "$REPO_DIR/$pf.sig" ] && [ -z "${ASSET_IDS[$pf.sig]:-}" ]; then
                echo "  missing .sig asset: $pf.sig"
                need_publish=1
                MISSING_FILES["$pf.sig"]=1
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

# db 引用完整性：release 上的 db 引用的每个包文件必须实际存在。
# publish 中断在“删除旧资产后 / db 重建前”会造成悬空引用（如 rustrover
# 2026.2-1 已删而 db 仍指向它），pacman 用户会 404；即使全部包版本
# 未变也必须强制重发布重建 db。
if [ -n "${ASSET_IDS[arch_lib.db.tar.gz]:-}" ]; then
    db_tmp=$(mktemp)
    if curl -fsSL --max-time 30 --retry 3 --retry-all-errors --retry-delay 2 \
        -H "$AUTH" "$DOWNLOAD/arch_lib.db.tar.gz" -o "$db_tmp" 2>/dev/null; then
        while IFS= read -r entry; do
            # With pipefail enabled, bsdtar can return SIGPIPE when awk exits
            # after the first FILENAME field.  That status must not abort the
            # whole publish before the repair/upload phase starts.
            fn=$(bsdtar -xOf "$db_tmp" "$entry" 2>/dev/null \
                | awk '/^%FILENAME%$/{getline; print}' || true)
            [ -n "$fn" ] || continue
            if [ -z "${ASSET_IDS[$fn]:-}" ]; then
                echo "  db references missing asset: $fn"
                need_publish=1
            fi
        done < <(bsdtar -tf "$db_tmp" 2>/dev/null | grep '/desc$' || true)
    else
        echo "  ⚠ db download failed — skipping integrity check"
    fi
    rm -f "$db_tmp"
fi

if [ "$need_publish" -eq 0 ]; then
    echo "== All package versions unchanged and assets complete — release untouched =="
    exit 0
fi

# ── 4. 上传/删除辅助（先删同名再传 = 幂等）─────────────────────────
delete_asset() { # <name>
    local name="$1"
    if [ -n "${ASSET_IDS[$name]:-}" ]; then
        # Retry on 5xx/429 (GitHub rate limit / transient errors), like upload does
        # --retry-all-errors retries on 5xx, 429, and connection failures
        # Treat 404 as success (asset already gone = idempotent)
        local http_code
        http_code=$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 \
            -X DELETE -H "$AUTH" "$API/releases/assets/${ASSET_IDS[$name]}" \
            -o /dev/null -w '%{http_code}')
        case "$http_code" in
            204|404)
                echo "  deleted: $name"
                unset 'ASSET_IDS[$name]'
                ;;
            *)
                echo "  ✗ delete failed (HTTP $http_code) after retries: $name" >&2
                return 1
                ;;
        esac
    fi
}

# 上传结果回传通道：xargs 并行子进程无法修改父 shell 的关联数组，
# 成功时把 name<TAB>asset_id 追加到 UPLOAD_LOG，父进程 sync_uploaded
# 合并进 UPLOADED（本轮去重）和 ASSET_IDS（保持 map 与 release 一致）。
UPLOAD_LOG=$(mktemp)
declare -A UPLOADED=()

upload_asset() { # <name> <file>
    local name="$1" file="$2"
    local encoded resp id
    encoded=$(jq -rn --arg v "$name" '$v|@uri')
    resp=$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 \
        -X POST -H "$AUTH" -H "Content-Type: application/octet-stream" \
        --data-binary @"$file" "$UPLOAD/releases/$RELEASE_ID/assets?name=$encoded") \
        || { echo "  ✗ upload failed: $name"; return 1; }
    id=$(printf '%s' "$resp" | jq -r '.id' 2>/dev/null || true)
    printf '%s\t%s\n' "$name" "$id" >> "$UPLOAD_LOG"
    echo "  uploaded: $name"
}

sync_uploaded() { # 合并子进程/本轮已完成的上传结果
    [ -s "$UPLOAD_LOG" ] || return 0
    while IFS=$'\t' read -r name id; do
        [ -n "$name" ] || continue
        UPLOADED["$name"]=1
        ASSET_IDS["$name"]="$id"
    done < "$UPLOAD_LOG"
    : > "$UPLOAD_LOG"
}
export -f upload_asset
export TOKEN RELEASE_ID UPLOAD AUTH UPLOAD_LOG

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
        if [ -n "${UPLOADED[$pf]:-}" ]; then
            # split 包（rustrover/rustrover-jre）的 manifest 共享同名文件：
            # 本轮已上传成功，REPO_DIR 内同名即同一文件（.sig 也已同批处理），
            # 再删再传只会撞 GitHub 422（asset already exists）
            echo "  already uploaded this run: $pf (+sig)"
            continue
        fi
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
        # xargs 任一子进程失败返回 123；先吞掉避免 set -e 直接杀死脚本，
        # 由下面的 sync + 校验统一判定失败并给出可读错误
        printf '%s\n' "${to_upload[@]}" | xargs -P 6 -I{} bash -c 'upload_asset "$(basename "{}")" "{}"' || true
        sync_uploaded
        # 上传必须全部成功：旧资产已删，若有失败立即中止（rerun 幂等，
        # 下次运行从 release 现状重查资产并补传）
        for f in "${to_upload[@]}"; do
            n=$(basename "$f")
            if [ -z "${UPLOADED[$n]:-}" ]; then
                echo "  ✗ upload failed: $n — aborting (rerun to retry)"
                exit 1
            fi
        done
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
sync_uploaded

# ── 5c. 补齐缺失的包文件（版本未变但资产缺失：上次发布可能中断在
# 删除之后/上传之前，db 重建后该包会 404，必须补传）──────────────────
for name in "${!MISSING_FILES[@]}"; do
    f="$REPO_DIR/$name"
    [ -f "$f" ] || { echo "  ✗ missing file in repo: $f"; exit 1; }
    if [ -n "${ASSET_IDS[$name]:-}" ]; then
        # 本轮前面步骤已补齐（changed 包重传 / split 包去重路径）
        continue
    fi
    echo "  backfilling asset: $name"
    upload_asset "$name" "$f"
done
sync_uploaded

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
