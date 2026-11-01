#!/usr/bin/env bash
set -euo pipefail
dir="${1:?AUR PKGBUILD directory required}"
package="${2:?Python tree-sitter grammar package required}"
[[ "$package" == python-tree-sitter-* ]] || { echo "Not a Python tree-sitter grammar: $package" >&2; exit 1; }
native="${package#python-}"
recipe="$dir/PKGBUILD"
test -f "$recipe" || { echo "Missing PKGBUILD: $recipe" >&2; exit 1; }
if grep -q '^# BEGIN arch_lib Python grammar embedded runtime$' "$recipe"; then exit 0; fi

# Source package metadata as makepkg does: AUR often uses tree-sitter-X=${pkgver}.
if ! (cd "$dir" && bash -c '
    source ./PKGBUILD
    for dep in "${depends[@]}"; do
        [[ "$dep" == "$1" || "$dep" == "$1="* || "$dep" == "$1>"* || "$dep" == "$1<"* ]] && exit 0
    done
    exit 1
' _ "$native"); then
    exit 0
fi

# This correction is restricted to self-contained Python PEP-517 grammar
# wheels; do not strip native dependencies from mere Python wrappers.
if ! grep -Eq 'python(3)?[[:space:]]+-m[[:space:]]+(build|installer)' "$recipe"; then
    echo "[hook] $package depends on $native but does not build a recognized Python wheel" >&2
    exit 1
fi
cat >> "$recipe" <<'PKGBUILD_PATCH'

# BEGIN arch_lib Python grammar embedded runtime
_arch_lib_grammar_native="${pkgname#python-}"
_arch_lib_grammar_deps=()
_arch_lib_grammar_removed=0
for _arch_lib_grammar_dep in "${depends[@]}"; do
    case "$_arch_lib_grammar_dep" in
        "$_arch_lib_grammar_native"|"$_arch_lib_grammar_native"[=\<\>]*)
            _arch_lib_grammar_removed=$((_arch_lib_grammar_removed + 1)) ;;
        *) _arch_lib_grammar_deps+=("$_arch_lib_grammar_dep") ;;
    esac
done
if (( _arch_lib_grammar_removed != 1 )); then
    printf '[arch_lib] expected one native grammar dependency for %s, found %s\n' "$pkgname" "$_arch_lib_grammar_removed" >&2
    return 1
fi
depends=("${_arch_lib_grammar_deps[@]}")
pkgrel=$((pkgrel + 1))
unset _arch_lib_grammar_native _arch_lib_grammar_deps _arch_lib_grammar_dep _arch_lib_grammar_removed
# END arch_lib Python grammar embedded runtime
PKGBUILD_PATCH
bash -n "$recipe"
(
    cd "$dir"
    bash -c '
        source ./PKGBUILD
        native="${pkgname#python-}"
        for dep in "${depends[@]}"; do
            case "$dep" in "$native"|"$native"[=\<\>]*) echo "Native grammar dependency remains: $dep" >&2; exit 1;; esac
        done
    '
)
echo "[hook] $package: removed separate native grammar dependency $native"
