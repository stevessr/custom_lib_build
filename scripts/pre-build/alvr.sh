#!/bin/bash
set -euo pipefail
# ALVR 20.14.1 locks libspa-sys 0.8 / bindgen 0.69, generating
# an incompatible spa_pod_builder struct on modern PipeWire/LLVM.
# Fedora fixed the same crate by upgrading bindgen to 0.72.1.
dir="${1:?PKGBUILD directory required}"
recipe="$dir/PKGBUILD"
test -f "$recipe"
if grep -q '^# BEGIN arch_lib ALVR PipeWire compatibility$' "$recipe"; then exit 0; fi
cat >> "$recipe" <<'PKGBUILD_PATCH'

# BEGIN arch_lib ALVR PipeWire compatibility
pkgrel=$((pkgrel + 1))
if ! declare -f prepare >/dev/null; then
    echo "ALVR recipe has no prepare() hook" >&2
    exit 1
fi
eval "$(declare -f prepare | sed '1s/^prepare[[:space:]]*()/_arch_lib_alvr_original_prepare ()/')"
prepare() {
    _arch_lib_alvr_original_prepare || return 1
    bash "$GITHUB_WORKSPACE/scripts/patch-alvr-libspa.sh" "$srcdir/alvr"
    if [ ! -f "$srcdir/alvr/Cargo.lock" ]; then
        echo "ALVR source has no Cargo.lock to update openssl-sys" >&2
        return 1
    fi
    cargo update --manifest-path "$srcdir/alvr/Cargo.toml" -p openssl --precise 0.10.82
    cargo update --manifest-path "$srcdir/alvr/Cargo.toml" -p openssl-sys --precise 0.9.118
    cargo fetch --locked --manifest-path "$srcdir/alvr/Cargo.toml"
}
# END arch_lib ALVR PipeWire compatibility
PKGBUILD_PATCH
bash -n "$recipe"
