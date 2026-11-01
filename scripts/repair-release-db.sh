#!/usr/bin/env bash
set -euo pipefail
mode="${1:---dry-run}"
case "$mode" in --dry-run|--apply) ;; *) echo 'Usage: repair_release_db.sh --dry-run|--apply' >&2; exit 2;; esac
: "${GITHUB_REPOSITORY:?}"
: "${GH_TOKEN:?}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$work"
auth="Authorization: Bearer $GH_TOKEN"
api="https://api.github.com/repos/$GITHUB_REPOSITORY"
dl="https://github.com/$GITHUB_REPOSITORY/releases/download/latest"
release=$(curl -fsSL --retry 4 -H "$auth" "$api/releases/tags/latest")
release_id=$(jq -er .id <<<"$release")
: > assets.jsonl
page=1
while :; do
    chunk=$(curl -fsSL --retry 4 -H "$auth" "$api/releases/$release_id/assets?per_page=100&page=$page")
    [ "$(jq length <<<"$chunk")" -gt 0 ] || break
    jq -c '.[] | {id,name,size,digest}' <<<"$chunk" >> assets.jsonl
    page=$((page+1))
done
mkdir -p original packages regenerated
for name in arch_lib.db.tar.gz arch_lib.files.tar.gz arch_lib.pub.asc; do
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 "$dl/$name" -o "original/$name"
done
python3 "$repo_root/scripts/release-asset-audit.py" original/arch_lib.db.tar.gz assets.jsonl original-report.json
count=$(jq '.mismatches | length' original-report.json)
if [ "$count" -eq 0 ]; then
    echo "Repository is already consistent: no changes required"
    exit 0
fi
if jq -e '.mismatches[] | select(.reasons[]=="asset_missing")' original-report.json >/dev/null; then
    echo 'Index refers to missing assets; refusing to fix hashes only' >&2
    exit 1
fi
# Import the public signing key and verify every online package signature.
gpg --batch --import original/arch_lib.pub.asc >/dev/null 2>&1
while IFS= read -r row; do
    name=$(jq -r .filename <<<"$row")
    encoded=$(jq -rn --arg v "$name" '$v|@uri')
    echo "Verify $name"
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 "$dl/$encoded" -o "packages/$name.part"
    bytes=$(stat -c %s "packages/$name.part")
    expected_bytes=$(jq -r --arg n "$name" 'select(.name==$n).size' assets.jsonl)
    test "$bytes" = "$expected_bytes" || { echo "Size mismatch downloading $name" >&2; exit 1; }
    sha=$(sha256sum "packages/$name.part" | cut -d' ' -f1)
    expected_sha=$(jq -r --arg n "$name" 'select(.name==$n).digest' assets.jsonl)
    test "$expected_sha" = "sha256:$sha" || { echo "GitHub digest mismatch for $name" >&2; exit 1; }
    mv "packages/$name.part" "packages/$name"
    zstd -tq "packages/$name"
    bsdtar -tf "packages/$name" >/dev/null
    # keep packages unchanged and require their published signature.
    if ! jq -e --arg n "$name.sig" 'select(.name==$n)' assets.jsonl >/dev/null; then
        echo "Published package is missing detached GPG signature: $name" >&2
        exit 1
    fi
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 "$dl/$encoded.sig" -o "packages/$name.sig"
    gpg --batch --verify "packages/$name.sig" "packages/$name"
    python3 - "$row" "packages/$name" <<'PY'
import json, subprocess,sys
expected=json.loads(sys.argv[1])
raw=subprocess.check_output(['pacman','-Qip',sys.argv[2]],text=True)
fields={line.split(':',1)[0].strip():line.split(':',1)[1].strip() for line in raw.splitlines() if ':' in line}
for db, pkg in [('name','Name'),('version','Version'),('arch','Architecture')]:
    if expected[db] and expected[db]!=fields.get(pkg):
        raise SystemExit(f"Unexpected package metadata {db}: {expected[db]} != {fields.get(pkg)}")
PY
done < <(jq -c '.mismatches[]' original-report.json)
cp original/arch_lib.db.tar.gz regenerated/arch_lib.db.tar.gz
cp original/arch_lib.files.tar.gz regenerated/arch_lib.files.tar.gz
if [ "$mode" = '--apply' ]; then
    : "${GPG_PRIVATE_KEY:?GPG private key is required to repair signed database}"
    printf '%s\n' "$GPG_PRIVATE_KEY" | gpg --batch --import >/dev/null
    fpr=$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10;exit}')
    test -n "$fpr"
    (cd regenerated && GPGKEY="$fpr" repo-add --sign arch_lib.db.tar.gz ../packages/*.pkg.tar.zst)
else
    (cd regenerated && repo-add arch_lib.db.tar.gz ../packages/*.pkg.tar.zst)
fi
rm -f regenerated/arch_lib.db regenerated/arch_lib.files
cp regenerated/arch_lib.db.tar.gz regenerated/arch_lib.db
cp regenerated/arch_lib.files.tar.gz regenerated/arch_lib.files
if [ "$mode" = '--apply' ]; then
    for base in arch_lib.db arch_lib.files; do
        [ -s "regenerated/$base.tar.gz.sig" ] || gpg --batch --yes --detach-sign --local-user "$fpr" -o "regenerated/$base.tar.gz.sig" "regenerated/$base.tar.gz"
        cp "regenerated/$base.tar.gz.sig" "regenerated/$base.sig"
    done
fi
python3 "$repo_root/scripts/release-asset-audit.py" regenerated/arch_lib.db.tar.gz assets.jsonl regenerated-report.json
remaining=$(jq '.mismatches | length' regenerated-report.json)
[ "$remaining" -eq 0 ] || { echo "Repaired database still has $remaining mismatches" >&2; exit 1; }
before=$(jq .indexed original-report.json)
after=$(jq .indexed regenerated-report.json)
[ "$after" -eq "$before" ] || { echo 'Rebuild changed package count' >&2; exit 1; }
echo "Validated all $count repaired entries; index retains $after packages"
if [ "$mode" = '--dry-run' ]; then
    echo 'Dry run complete: public GitHub Release unchanged.'
    exit 0
fi
# Back up every canonical database file before replacing any asset.
mkdir -p backup
names=(arch_lib.db arch_lib.db.tar.gz arch_lib.files arch_lib.files.tar.gz)
for base in arch_lib.db arch_lib.files; do names+=("$base.sig" "$base.tar.gz.sig"); done
for name in "${names[@]}"; do
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 "$dl/$name" -o "backup/$name"
done
# Check that no concurrent publisher has changed any package or db asset.
: > current-assets.jsonl
page=1
while :; do
    chunk=$(curl -fsSL --retry 4 -H "$auth" "$api/releases/$release_id/assets?per_page=100&page=$page")
    [ "$(jq length <<<"$chunk")" -gt 0 ] || break
    jq -c '.[] | {id,name,size,digest}' <<<"$chunk" >> current-assets.jsonl
    page=$((page+1))
done
if ! diff -q <(jq -r '.name+":"+(.id|tostring)+":"+(.digest//"")' assets.jsonl | sort) <(jq -r '.name+":"+(.id|tostring)+":"+(.digest//"")' current-assets.jsonl | sort); then
    echo 'Release assets changed during validation; aborting without mutation' >&2
    exit 1
fi
# gh upload --clobber updates flat Release names. Retain local backup and 
# attempt rollback if any upload/verification fails.
export GH_TOKEN
success=0
rollback() {
    if [ "$success" -eq 0 ]; then
        echo 'Repair failed; restoring previous signed database assets' >&2
        gh release upload latest backup/* --clobber -R "$GITHUB_REPOSITORY" || true
    fi
}
trap rollback ERR
upload_files=()
for name in "${names[@]}"; do upload_files+=("regenerated/$name"); done
gh release upload latest "${upload_files[@]}" --clobber -R "$GITHUB_REPOSITORY"
# Verify uploaded DB asset matches exactly the local rebuilt DB.
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 "$dl/arch_lib.db.tar.gz" -o final.db.tar.gz
cmp -s final.db.tar.gz regenerated/arch_lib.db.tar.gz || { echo 'Remote repaired db mismatch' >&2; false; }
success=1
trap - ERR
echo 'Repaired and uploaded signed database only; package assets left unchanged.'
