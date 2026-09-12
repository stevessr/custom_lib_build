#!/bin/bash
#
# check-git-repos.sh — 检查 ~/文档 下所有普通 Git 工作树的状态，并修复
# 可安全自愈的 Git 元数据损坏。
#
# 可修复：
#   - 损坏/截断/缺失的 index（只重建 index，不改工作区文件；原暂存状态
#     无法从损坏的 index 可靠恢复，重建后以工作区内容为准）；
#   - 内容非法的 loose ref（优先恢复 packed-refs/reflog，远程 ref 则备份后
#     删除并在需要时重新 fetch）。
#
# 不会自动删除无法恢复的本地分支、tag 或对象；这类问题会报告出来，避免
# 把真正的数据丢失伪装成“修好了”。每次修复前都会把原始元数据备份到
# /tmp/git-repair-*。
#
# Usage:
#   scripts/check-git-repos.sh [options]
#
# Options:
#   --root DIR     扫描 DIR（默认 "$HOME/文档"）
#   --fetch        对每个仓库执行 git fetch --all --prune 后再报告状态
#   --dry-run      只检测并显示将要修复的内容，不写入任何文件
#   -v, --verbose  显示 fsck/fetch 的非错误输出
#
set -uo pipefail
IFS=$'\n\t'

ROOT="${HOME}/文档"
FETCH_ALL=0
DRY_RUN=0
VERBOSE=0
BACKUP_ROOT=""

REPO_COUNT=0
CLEAN_COUNT=0
DIRTY_COUNT=0
FAILED_COUNT=0
REPAIR_COUNT=0

CURRENT_BACKUP_DIR=""
LAST_BACKUP=""
NEEDS_FETCH=0
FSCK_FAILED=0

usage() {
    sed -n '1,34p' "$0"
}

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

indent_output() {
    local text="${1:-}"
    while IFS= read -r line; do
        printf '    %s\n' "$line"
    done <<< "$text"
}

# 清掉调用者可能设置的 GIT_* 环境变量，避免污染被扫描的仓库。
gitc() {
    local repo="$1"
    shift
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$repo" "$@"
}

ensure_backup_root() {
    if [[ -z "$BACKUP_ROOT" ]]; then
        BACKUP_ROOT="${TMPDIR:-/tmp}/git-repair-$(date +%Y%m%d-%H%M%S)-$$"
        mkdir -p -- "$BACKUP_ROOT" || return 1
    fi
}

set_repo_backup_dir() {
    local repo="$1"
    local key

    key="$(printf '%s' "$repo" | sha256sum | awk '{print substr($1, 1, 16)}')"
    CURRENT_BACKUP_DIR="$BACKUP_ROOT/$key"
    mkdir -p -- "$CURRENT_BACKUP_DIR" || return 1
    printf '%s\n' "$repo" > "$CURRENT_BACKUP_DIR/repository"
}

backup_copy() {
    local repo="$1"
    local source="$2"
    local label="$3"

    ensure_backup_root || return 1
    set_repo_backup_dir "$repo" || return 1
    LAST_BACKUP="$CURRENT_BACKUP_DIR/$label"
    if [[ -e "$LAST_BACKUP" || -L "$LAST_BACKUP" ]]; then
        LAST_BACKUP="$LAST_BACKUP.$(date +%s%N)"
    fi
    cp -a -- "$source" "$LAST_BACKUP"
}

backup_then_remove() {
    local repo="$1"
    local source="$2"
    local label="$3"

    if (( DRY_RUN )); then
        info "[$repo] dry-run: backup/remove $source"
        return 0
    fi

    if ! backup_copy "$repo" "$source" "$label"; then
        warn "[$repo] 无法备份 $source，跳过修复"
        return 1
    fi
    if ! rm -f -- "$source"; then
        warn "[$repo] 无法移除损坏文件 $source；备份在 $LAST_BACKUP"
        return 1
    fi
    return 0
}

absolute_git_dir() {
    local repo="$1"
    local dir

    dir="$(gitc "$repo" rev-parse --absolute-git-dir 2>/dev/null)" || {
        dir="$(gitc "$repo" rev-parse --git-dir 2>/dev/null)" || return 1
        if [[ "$dir" != /* ]]; then
            dir="$repo/$dir"
        fi
        dir="$(cd -- "$dir" 2>/dev/null && pwd -P)" || return 1
    }
    printf '%s\n' "$dir"
}

absolute_common_dir() {
    local repo="$1"
    local dir

    dir="$(gitc "$repo" rev-parse --git-common-dir 2>/dev/null)" || return 1
    if [[ "$dir" != /* ]]; then
        dir="$repo/$dir"
    fi
    dir="$(cd -- "$dir" 2>/dev/null && pwd -P)" || return 1
    printf '%s\n' "$dir"
}

oid_length() {
    local repo="$1"
    local format

    format="$(gitc "$repo" rev-parse --show-object-format 2>/dev/null || true)"
    if [[ "$format" == sha256 ]]; then
        printf '64\n'
    else
        printf '40\n'
    fi
}

oid_exists() {
    local repo="$1"
    local oid="$2"
    [[ -n "$oid" ]] || return 1
    gitc "$repo" cat-file -e "${oid}^{object}" >/dev/null 2>&1
}

# 输出 loose ref 的状态：valid、symbolic、missing、invalid。
loose_ref_state() {
    local repo="$1"
    local file="$2"
    local length="$3"
    local line rest

    line="$(head -n 1 -- "$file" 2>/dev/null || true)"
    rest="$(tail -n +2 -- "$file" 2>/dev/null || true)"

    if [[ -n "$rest" ]]; then
        printf 'invalid\n'
        return
    fi

    if [[ "$line" =~ ^ref:\ refs/[A-Za-z0-9._/-]+$ ]]; then
        printf 'symbolic\n'
        return
    fi

    if [[ ${#line} -eq $length && "$line" =~ ^[0-9a-fA-F]+$ ]]; then
        if oid_exists "$repo" "$line"; then
            printf 'valid\n'
        else
            printf 'missing\n'
        fi
        return
    fi

    printf 'invalid\n'
}

packed_oid_for_ref() {
    local common_dir="$1"
    local ref_name="$2"
    local packed="$common_dir/packed-refs"

    [[ -f "$packed" ]] || return 0
    awk -v wanted="$ref_name" '
        $0 !~ /^#/ && $0 !~ /^\^/ && $2 == wanted { print $1; exit }
    ' "$packed" 2>/dev/null || true
}

last_reflog_oid() {
    local repo="$1"
    local common_dir="$2"
    local ref_name="$3"
    local reflog="$common_dir/logs/$ref_name"
    local record old_oid new_oid candidate=""

    [[ -f "$reflog" ]] || return 0
    while IFS= read -r record; do
        old_oid="${record%% *}"
        record="${record#* }"
        new_oid="${record%% *}"
        if [[ "$new_oid" != "$old_oid" ]] && oid_exists "$repo" "$new_oid"; then
            candidate="$new_oid"
        fi
    done < "$reflog"
    printf '%s\n' "$candidate"
}

repair_bad_ref() {
    local repo="$1"
    local common_dir="$2"
    local ref_file="$3"
    local ref_name="$4"
    local length="$5"
    local state="$6"
    local packed_oid recovery_oid label

    packed_oid="$(packed_oid_for_ref "$common_dir" "$ref_name")"
    if [[ ${#packed_oid} -eq $length ]] && oid_exists "$repo" "$packed_oid"; then
        label="bad-${ref_name//\//__}"
        if backup_then_remove "$repo" "$ref_file" "$label"; then
            REPAIR_COUNT=$((REPAIR_COUNT + 1))
            [[ "$ref_name" == refs/remotes/* ]] && NEEDS_FETCH=1
            info "[$repo] 已移除损坏 loose ref $ref_name，回退到 packed-refs"
        fi
        return
    fi

    if [[ "$ref_name" == refs/heads/* ]]; then
        recovery_oid="$(last_reflog_oid "$repo" "$common_dir" "$ref_name")"
        if [[ ${#recovery_oid} -eq $length ]] && oid_exists "$repo" "$recovery_oid"; then
            label="bad-${ref_name//\//__}"
            if backup_then_remove "$repo" "$ref_file" "$label"; then
                if (( ! DRY_RUN )); then
                    if ! gitc "$repo" update-ref "$ref_name" "$recovery_oid"; then
                        warn "[$repo] 无法用 reflog 恢复 $ref_name"
                        cp -a -- "$LAST_BACKUP" "$ref_file" 2>/dev/null || true
                        return
                    fi
                fi
                REPAIR_COUNT=$((REPAIR_COUNT + 1))
                info "[$repo] 已用 reflog 恢复 $ref_name -> $recovery_oid"
            fi
            return
        fi
        warn "[$repo] $ref_name ($state) 无可验证的 packed-refs/reflog，未删除"
        return
    fi

    if [[ "$ref_name" == refs/remotes/* ]]; then
        label="bad-${ref_name//\//__}"
        if backup_then_remove "$repo" "$ref_file" "$label"; then
            REPAIR_COUNT=$((REPAIR_COUNT + 1))
            NEEDS_FETCH=1
            info "[$repo] 已移除损坏远程 ref $ref_name，稍后重新 fetch"
        fi
        return
    fi

    warn "[$repo] $ref_name ($state) 无安全恢复来源，未删除"
}

scan_loose_refs() {
    local repo="$1"
    local common_dir="$2"
    local length="$3"
    local ref_file ref_name state

    [[ -d "$common_dir/refs" ]] || return 0
    while IFS= read -r -d '' ref_file; do
        [[ "$ref_file" == *.lock ]] && continue
        ref_name="${ref_file#"$common_dir/"}"
        state="$(loose_ref_state "$repo" "$ref_file" "$length")"
        if ! gitc "$repo" check-ref-format "$ref_name" >/dev/null 2>&1; then
            state=invalid
        fi
        case "$state" in
            invalid|missing)
                warn "[$repo] 检测到损坏 ref: $ref_name ($state)"
                repair_bad_ref "$repo" "$common_dir" "$ref_file" "$ref_name" "$length" "$state"
                ;;
        esac
    done < <(find "$common_dir/refs" -type f -print0 2>/dev/null)
}

repair_index() {
    local repo="$1"
    local git_dir="$2"
    local index="$git_dir/index"
    local head_exists=0

    if (( DRY_RUN )); then
        info "[$repo] dry-run: 重建损坏的 index（不会修改工作区文件）"
        REPAIR_COUNT=$((REPAIR_COUNT + 1))
        return 0
    fi

    if [[ -e "$index" || -L "$index" ]]; then
        if ! backup_copy "$repo" "$index" index.corrupt; then
            warn "[$repo] 无法备份损坏 index，跳过重建"
            return 1
        fi
        if ! rm -f -- "$index"; then
            warn "[$repo] 无法移除损坏 index；备份在 $LAST_BACKUP"
            return 1
        fi
    fi

    if gitc "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
        head_exists=1
    fi

    if (( head_exists )); then
        if ! gitc "$repo" read-tree HEAD >/dev/null 2>&1; then
            warn "[$repo] read-tree HEAD 失败，尝试恢复原 index"
            [[ -n "$LAST_BACKUP" && -e "$LAST_BACKUP" ]] && cp -a -- "$LAST_BACKUP" "$index"
            return 1
        fi
    elif ! gitc "$repo" read-tree --empty >/dev/null 2>&1; then
        warn "[$repo] 无法为 unborn HEAD 创建空 index"
        [[ -n "$LAST_BACKUP" && -e "$LAST_BACKUP" ]] && cp -a -- "$LAST_BACKUP" "$index"
        return 1
    fi

    REPAIR_COUNT=$((REPAIR_COUNT + 1))
    info "[$repo] 已重建 index；工作区文件未被修改"
    return 0
}

collect_status() {
    local repo="$1"
    STATUS_OUTPUT="$(gitc "$repo" status --short --branch --ahead-behind 2>&1)"
    STATUS_RC=$?
}

status_is_index_error() {
    local output="$1"
    grep -Eiq 'bad signature|index file (corrupt|smaller than expected|invalid)|shared index file|could not read index|fatal: index file' <<< "$output"
}

fetch_repo() {
    local repo="$1"
    local output rc

    info "[$repo] fetch --all --prune"
    output="$(gitc "$repo" fetch --all --prune 2>&1)"
    rc=$?
    if (( rc != 0 )); then
        warn "[$repo] fetch 失败 (exit $rc)"
        indent_output "$output"
    elif (( VERBOSE )) && [[ -n "$output" ]]; then
        indent_output "$output"
    fi
    return "$rc"
}

check_fsck() {
    local repo="$1"
    local output rc errors

    FSCK_FAILED=0
    output="$(gitc "$repo" fsck --no-progress --connectivity-only 2>&1)"
    rc=$?
    errors="$(printf '%s\n' "$output" | grep -Ei \
        '^(error:|fatal:)|badRefContent|invalid .*pointer|missing (blob|tree|commit|tag)' || true)"

    if (( rc != 0 )) || [[ -n "$errors" ]]; then
        FSCK_FAILED=1
        warn "[$repo] fsck 仍报告问题"
        indent_output "$output"
    elif (( VERBOSE )) && [[ -n "$output" ]]; then
        indent_output "$output"
    fi
}

process_repo() {
    local repo="$1"
    local git_dir common_dir length before_repairs
    local fetch_rc=0

    REPO_COUNT=$((REPO_COUNT + 1))
    NEEDS_FETCH=0
    FSCK_FAILED=0
    before_repairs=$REPAIR_COUNT

    printf '\n[%d] %s\n' "$REPO_COUNT" "$repo"
    git_dir="$(absolute_git_dir "$repo")" || {
        warn "无法读取 git dir，跳过"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return
    }
    common_dir="$(absolute_common_dir "$repo")" || common_dir="$git_dir"
    length="$(oid_length "$repo")"

    scan_loose_refs "$repo" "$common_dir" "$length"

    if [[ ! -e "$git_dir/index" && ! -L "$git_dir/index" ]]; then
        warn "[$repo] index 不存在，将重建"
        repair_index "$repo" "$git_dir" || true
    fi

    collect_status "$repo"
    if (( STATUS_RC != 0 )) && status_is_index_error "$STATUS_OUTPUT"; then
        repair_index "$repo" "$git_dir" || true
        collect_status "$repo"
    fi

    if (( (FETCH_ALL || NEEDS_FETCH) && !DRY_RUN )); then
        fetch_repo "$repo" || fetch_rc=$?
        collect_status "$repo"
    elif (( FETCH_ALL || NEEDS_FETCH )); then
        info "[$repo] dry-run: 跳过 fetch"
    fi

    check_fsck "$repo"

    if (( STATUS_RC != 0 )); then
        warn "status 失败 (exit $STATUS_RC)"
        indent_output "$STATUS_OUTPUT"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    else
        indent_output "$STATUS_OUTPUT"
        if printf '%s\n' "$STATUS_OUTPUT" | grep -v '^##' | grep -q .; then
            DIRTY_COUNT=$((DIRTY_COUNT + 1))
        else
            CLEAN_COUNT=$((CLEAN_COUNT + 1))
        fi
        if (( fetch_rc != 0 || FSCK_FAILED )); then
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    fi

    if (( REPAIR_COUNT > before_repairs )); then
        info "[$repo] 本次修复数：$((REPAIR_COUNT - before_repairs))"
    fi
}

while (($#)); do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo '--root 需要目录参数' >&2; exit 2; }
            ROOT="$2"
            shift 2
            ;;
        --fetch)
            FETCH_ALL=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数：$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

ROOT="$(cd -- "$ROOT" 2>/dev/null && pwd -P)" || {
    echo "扫描目录不存在或不可访问：$ROOT" >&2
    exit 2
}

declare -a REPOS=()
declare -A SEEN=()

add_repo() {
    local path="$1"
    local absolute

    [[ -d "$path" ]] || return 0
    absolute="$(cd -- "$path" 2>/dev/null && pwd -P)" || return 0
    if [[ -z "${SEEN[$absolute]+seen}" ]]; then
        SEEN["$absolute"]=1
        REPOS+=("$absolute")
    fi
}

while IFS= read -r -d '' git_entry; do
    add_repo "${git_entry%/.git}"
done < <(
    find "$ROOT" \( -type d -name .git -prune -print0 \) -o \
        \( -type f -name .git -print0 \) 2>/dev/null
)

if ((${#REPOS[@]} == 0)); then
    info "在 $ROOT 下没有找到普通 Git 工作树"
    exit 0
fi

for repo in "${REPOS[@]}"; do
    process_repo "$repo"
done

printf '\n=== summary ===\n'
printf 'repositories: %d\n' "$REPO_COUNT"
printf 'clean:        %d\n' "$CLEAN_COUNT"
printf 'dirty:        %d\n' "$DIRTY_COUNT"
printf 'repairs:      %d\n' "$REPAIR_COUNT"
printf 'failed:       %d\n' "$FAILED_COUNT"
if [[ -n "$BACKUP_ROOT" ]]; then
    printf 'backups:      %s\n' "$BACKUP_ROOT"
fi

if (( FAILED_COUNT != 0 )); then
    exit 1
fi
exit 0
