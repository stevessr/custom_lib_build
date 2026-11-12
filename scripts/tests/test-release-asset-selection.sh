#!/usr/bin/env bash
# Regression: reuse must select assets by exact package name (plus split
# siblings), never by bare "<pkg>-" prefix. Otherwise python-tree-sitter
# reuse picks python-tree-sitter-objc 3.0.2 files, publish deletes the real
# python-tree-sitter 0.26.0 asset, and every python-tree-sitter-* build then
# fails with a 404 when installing its python-tree-sitter dependency.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
selector="$root/scripts/release-asset-selection.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/assets.txt" <<'EOF'
python-tree-sitter-0.26.0-1-x86_64.pkg.tar.zst
python-tree-sitter-0.26.0-1-x86_64.pkg.tar.zst.sig
python-tree-sitter-debug-0.26.0-1-x86_64.pkg.tar.zst
python-tree-sitter-objc-3.0.2-10-x86_64.pkg.tar.zst
python-tree-sitter-objc-debug-3.0.2-10-x86_64.pkg.tar.zst
python-tree-sitter-julia-0.25.0-4-x86_64.pkg.tar.zst
python-tree-sitter-julia-debug-0.25.0-4-x86_64.pkg.tar.zst
python-conda-26.9.3-1-any.pkg.tar.zst
python-conda-libmamba-solver-26.7.0-1-any.pkg.tar.zst
wechat-1_17-1-any.pkg.tar.zst
wechat-1_18-1-any.pkg.tar.zst
wechat-bin-4.1.13.26-1-x86_64.pkg.tar.zst
android-sdk-26.1.1-2-x86_64.pkg.tar.zst
android-sdk-build-tools-r37.0.0-2-x86_64.pkg.tar.zst
rustrover-2026.2-1-x86_64.pkg.tar.zst
rustrover-jre-2026.2-1-x86_64.pkg.tar.zst
rustrover-debug-2026.2-1-x86_64.pkg.tar.zst
EOF

pick() {
    bash "$selector" "$1" "$2" "$tmp/assets.txt"
}

expect() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" != "$expected" ]; then
        printf 'FAIL: %s\nexpected:\n%s\nactual:\n%s\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

# A package whose name is a prefix of sibling packages must not absorb them.
expect "python-tree-sitter exact family" \
    "python-tree-sitter-0.26.0-1-x86_64.pkg.tar.zst
python-tree-sitter-debug-0.26.0-1-x86_64.pkg.tar.zst" \
    "$(pick python-tree-sitter python-tree-sitter)"

expect "python-tree-sitter-julia stays separate" \
    "python-tree-sitter-julia-0.25.0-4-x86_64.pkg.tar.zst
python-tree-sitter-julia-debug-0.25.0-4-x86_64.pkg.tar.zst" \
    "$(pick python-tree-sitter-julia python-tree-sitter-julia)"

expect "python-conda does not absorb python-conda-*" \
    "python-conda-26.9.3-1-any.pkg.tar.zst" \
    "$(pick python-conda python-conda)"

# Epoch colons are sanitized to "_" in published filenames; pick the newest.
expect "wechat picks newest epoch version" \
    "wechat-1_18-1-any.pkg.tar.zst" \
    "$(pick wechat wechat)"

expect "android-sdk does not absorb build-tools" \
    "android-sdk-26.1.1-2-x86_64.pkg.tar.zst" \
    "$(pick android-sdk android-sdk)"

# Genuine split packages still select every declared output.
expect "rustrover split family" \
    "rustrover-2026.2-1-x86_64.pkg.tar.zst
rustrover-debug-2026.2-1-x86_64.pkg.tar.zst
rustrover-jre-2026.2-1-x86_64.pkg.tar.zst" \
    "$(pick rustrover rustrover,rustrover-jre)"

# No matching assets is a clean no-result, not a failure.
: > "$tmp/empty.txt"
out="$(bash "$selector" missing-package missing-package "$tmp/empty.txt")"
[ -z "$out" ]

echo "release asset selection: exact-name, split-family and epoch checks passed"
