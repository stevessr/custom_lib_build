#!/usr/bin/env bash
# Regression: wine-gohryt-wayland-wow64's AUR recipe links with
# `-fuse-ld=mold` but does not declare mold in makedepends. The builder image
# only ships base-devel, so GCC 16 fails with the misleading
# "collect2: fatal error: cannot find 'ld'" during configure. The pre-build
# hook must install mold and prove the link works, or fail closed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$root/scripts/pre-build/wine-gohryt-wayland-wow64.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/sys" "$tmp/pkg" "$tmp/state"
for tool in bash cat chmod grep head mktemp rm sed sleep touch; do
    ln -s "$(command -v "$tool")" "$tmp/sys/$tool"
done
# Keep system ld.mold out of PATH so the hook sees a mold-less image.
path="$tmp/bin:$tmp/sys"

cat > "$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat > "$tmp/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
touch "$MOCK_STATE/pacman-called"
[ "${MOCK_PACMAN_FAIL:-0}" = 1 ] && exit 1
cat > "$MOCK_BIN/ld.mold" <<'MOLD'
#!/usr/bin/env bash
echo "mold 3.0.0 (mock)"
MOLD
chmod +x "$MOCK_BIN/ld.mold"
EOF
cat > "$tmp/bin/gcc" <<'EOF'
#!/usr/bin/env bash
if [ "${MOCK_GCC_FAIL:-0}" = 1 ] || ! command -v ld.mold >/dev/null 2>&1; then
    echo "collect2: fatal error: cannot find 'ld'" >&2
    exit 1
fi
exit 0
EOF
chmod +x "$tmp/bin/sudo" "$tmp/bin/pacman" "$tmp/bin/gcc"

write_recipe() {
    local mold="$1"
    if [ "$mold" = yes ]; then
        cat > "$tmp/pkg/PKGBUILD" <<'EOF'
pkgname=wine-gohryt-wayland-wow64
pkgver=11.19
build() {
  export LDFLAGS+=" -fuse-ld=mold"
  ../wine/configure
}
EOF
    else
        cat > "$tmp/pkg/PKGBUILD" <<'EOF'
pkgname=wine-gohryt-wayland-wow64
pkgver=11.19
build() {
  ../wine/configure
}
EOF
    fi
}

run_hook() {
    env PATH="$path" MOCK_BIN="$tmp/bin" MOCK_STATE="$tmp/state" \
        "$@" "$BASH" "$hook" "$tmp/pkg" wine-gohryt-wayland-wow64
}

reset_case() {
    rm -f "$tmp/bin/ld.mold" "$tmp/state/pacman-called"
}

# 1. Recipe no longer selects mold: hook is a no-op and does not touch pacman.
reset_case
write_recipe no
run_hook
[ ! -e "$tmp/state/pacman-called" ]

# 2. Recipe selects mold: hook installs it and the link probe succeeds.
reset_case
write_recipe yes
run_hook
[ -e "$tmp/state/pacman-called" ]
[ -x "$tmp/bin/ld.mold" ]

# 3. mold cannot be installed: fail closed instead of a cryptic configure error.
reset_case
write_recipe yes
if run_hook MOCK_PACMAN_FAIL=1 >/dev/null 2>&1; then
    echo "Expected hook to fail when mold cannot be installed" >&2
    exit 1
fi
[ ! -e "$tmp/bin/ld.mold" ]

# 4. mold is present but the link probe still fails: fail closed.
reset_case
write_recipe yes
if run_hook MOCK_GCC_FAIL=1 >/dev/null 2>&1; then
    echo "Expected hook to fail when -fuse-ld=mold cannot link" >&2
    exit 1
fi

echo "wine-gohryt-wayland-wow64 mold bootstrap: no-op/install/fail-closed checks passed"
