#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$root/scripts/pre-build/python-tree-sitter-grammar.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Cover version-pinned and unpinned native AUR dependency forms.
for language in ruby json; do
  dir="$tmp/$language"
  mkdir -p "$dir"
  cat > "$dir/PKGBUILD" <<EOF
pkgname=python-tree-sitter-$language
pkgver=0.24.8
pkgrel=1
depends=('tree-sitter-$language=0.24.8' 'python-tree-sitter' 'tree-sitter')
build() {
  python -m build --wheel
}
EOF
  bash "$hook" "$dir" "python-tree-sitter-$language"
  # Idempotent: running once from Graphify bootstrap and again from the
  # top-level matrix must not bump pkgrel twice.
  bash "$hook" "$dir" "python-tree-sitter-$language"
  bash -c '
    source "$1"
    [[ "$pkgrel" = 2 ]]
    [[ "${#depends[@]}" = 2 ]]
    [[ "${depends[0]}" = python-tree-sitter ]]
    [[ "${depends[1]}" = tree-sitter ]]
  ' _ "$dir/PKGBUILD"
  [[ "$(grep -c '^# BEGIN arch_lib Python grammar embedded runtime$' "$dir/PKGBUILD")" = 1 ]]
done

# Never silently remove a separate native grammar dependency from a package
# that does not build its own wheel; the caller must fail closed.
mkdir -p "$tmp/not-a-wheel"
cat > "$tmp/not-a-wheel/PKGBUILD" <<'EOF'
pkgname=python-tree-sitter-other
pkgver=1.0
pkgrel=1
depends=('tree-sitter-other' 'python-tree-sitter')
build() { make; }
EOF
if bash "$hook" "$tmp/not-a-wheel" python-tree-sitter-other >/dev/null 2>&1; then
  echo "Expected unsupported grammar recipe to fail closed" >&2
  exit 1
fi
! grep -q '^# BEGIN arch_lib Python grammar embedded runtime$' "$tmp/not-a-wheel/PKGBUILD"

echo "Python Tree-sitter embedded wheel patch: ruby/json and fail-closed checks passed"
