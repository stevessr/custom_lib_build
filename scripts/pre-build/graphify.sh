#!/bin/bash
set -euo pipefail
dir="$1"
test -f "$dir/PKGBUILD"
source "$GITHUB_WORKSPACE/scripts/pre-build/aur-deps-lib.sh"
# Read the actual upstream grammar list: removing hard dependencies makes
# multi-language graph extraction silently fail at runtime.
mapfile -t grammars < <(
    bash -c 'source "$1"; printf "%s\n" "${depends[@]}"' _ "$dir/PKGBUILD" |
    grep '^python-tree-sitter' || true
)
if (( ${#grammars[@]} < 20 )); then
    echo "[graphify] Incomplete tree-sitter language list" >&2
    exit 1
fi
echo "[graphify] Bootstrapping ${#grammars[@]} tree-sitter dependencies"
ensure_aur_deps "${grammars[@]}"
