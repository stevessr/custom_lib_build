#!/usr/bin/env bash
set -euo pipefail
dir="${1:?Python C++ grammar directory required}"
recipe="$dir/PKGBUILD"
test -f "$recipe" || { echo "Missing PKGBUILD" >&2; exit 1; }
if grep -q '^# BEGIN arch_lib self-contained C++ Python binding$' "$recipe"; then
    echo '[hook] Python C++ binding already adjusted'
    exit 0
fi
# Python tree_sitter_cpp.language() embeds its C++ grammar. It does not link
# the separate native tree-sitter-cpp runtime. The AUR package occasionally
# spells the native dependency as tree-sitter-cpp=${pkgver}; filtering the
# original text by literal version is unreliable.
cat >> "$recipe" <<'PKGBUILD_PATCH'

# BEGIN arch_lib self-contained C++ Python binding
_arch_lib_cpp_filtered=()
_arch_lib_cpp_removed=0
for _arch_lib_cpp_dep in "${depends[@]}"; do
    case "$_arch_lib_cpp_dep" in
        tree-sitter-cpp|tree-sitter-cpp[=\<\>]* )
            _arch_lib_cpp_removed=$((_arch_lib_cpp_removed + 1)) ;;
        *) _arch_lib_cpp_filtered+=("$_arch_lib_cpp_dep") ;;
    esac
done
if (( _arch_lib_cpp_removed > 1 )); then
    echo '[arch_lib] multiple native C++ grammar dependencies; refusing patch' >&2
    return 1
fi
depends=("${_arch_lib_cpp_filtered[@]}")
if (( _arch_lib_cpp_removed == 1 )); then
    pkgrel=$((pkgrel + 1))
fi
unset _arch_lib_cpp_filtered _arch_lib_cpp_dep _arch_lib_cpp_removed
# END arch_lib self-contained C++ Python binding
PKGBUILD_PATCH
bash -n "$recipe"
# Verify effective package metadata, not a source-text match.
(
    cd "$dir"
    bash -c '
        set -euo pipefail
        source ./PKGBUILD
        for dependency in "${depends[@]}"; do
            case "$dependency" in
                tree-sitter-cpp|tree-sitter-cpp[=\<\>]* )
                    echo "Native C++ grammar dependency remained: $dependency" >&2
                    exit 1 ;;
            esac
        done
        printf "[hook] Python C++ binding runtime deps: %s\n" "${depends[*]}"
    '
)
