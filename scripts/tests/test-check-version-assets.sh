#!/usr/bin/env bash
# Regression: a published version marker (and possibly .sig) does not mean
# the actual Arch package asset is available for reuse.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/workspace"

cat > "$tmp/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
case "$args" in
    *"rpc/v5/info"*)
        printf '%s\n' '{"results":[{"PackageBase":"python-conda-libmamba-solver"}]}'
        ;;
    *"plain/PKGBUILD"*)
        output=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-o" ]; then output="$2"; break; fi
            shift
        done
        [ -n "$output" ] || exit 2
        cat > "$output" <<'PKGBUILD'
pkgname=python-conda-libmamba-solver
pkgver=26.7.0
pkgrel=1
arch=('any')
PKGBUILD
        ;;
    *"version-python-conda-libmamba-solver.txt"*)
        if [ "${MOCK_PREV:-present}" = present ]; then
            printf '26.7.0\n'
        else
            printf '26.6.0\n'
        fi
        ;;
    *"python-conda-libmamba-solver-26.7.0-1-any.pkg.tar.zst"*)
        if [ "${MOCK_ASSET_EXISTS:-no}" = yes ]; then
            printf '200'
        else
            printf '404'
        fi
        ;;
    *)
        echo "Unexpected curl call: $args" >&2
        exit 2
        ;;
esac
MOCK_CURL
chmod +x "$tmp/bin/curl"

assert_decision() {
    local label="$1" previous="$2" available="$3" expected="$4"
    env PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY="stevessr/custom_lib_build" \
        GH_TOKEN="test-token" MOCK_PREV="$previous" MOCK_ASSET_EXISTS="$available" \
        bash "$root/scripts/check-version.sh" \
            python-conda-libmamba-solver "$tmp/workspace" "$tmp/result.env" >"$tmp/check.log"
    if ! grep -qxF "needs_build=$expected" "$tmp/result.env"; then
        echo "FAIL: $label (expected needs_build=$expected)" >&2
        cat "$tmp/result.env" "$tmp/check.log" >&2
        exit 1
    fi
    echo "PASS: $label"
}

assert_decision "version marker present, package binary missing" present no true
assert_decision "version marker present, package binary available" present yes false
assert_decision "version metadata stale, binary already uploaded" stale yes false
assert_decision "version metadata stale and binary missing" stale no true
