#!/usr/bin/env bash
# The JSON grammar wheel embeds its parser but still needs the Python tree-sitter
# runtime and Arch's core tree-sitter library. The latter comes from [extra];
# python-tree-sitter can come from arch_lib or be built from AUR as a fallback.
set -euo pipefail
dir="${1:?PKGBUILD directory required}"
test -f "$dir/PKGBUILD"
source "$GITHUB_WORKSPACE/scripts/pre-build/aur-deps-lib.sh"
ensure_aur_deps tree-sitter python-tree-sitter
python -c 'import tree_sitter; print("[tree-sitter-json] Python runtime import OK")'
