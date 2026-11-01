#!/bin/bash
# Bootstrap AUR-only runtime dependencies before makepkg -s resolves
# stirling-pdf-bin's dependencies. These are not in Arch's official repos,
# so a clean arch-builder image cannot install them via pacman alone.
#
# They are also in packages.txt for publication to arch_lib: end users
# should not need an AUR helper to install the resulting binary package.
set -euo pipefail

pkg_dir="${1:?Usage: stirling-pdf-bin.sh PKG_DIR PKG_NAME}"
pkg="${2:-stirling-pdf-bin}"
if [[ ! -f "$pkg_dir/PKGBUILD" ]]; then
    echo "  [hook] Missing PKGBUILD for $pkg" >&2
    exit 1
fi

source "$GITHUB_WORKSPACE/scripts/pre-build/aur-deps-lib.sh"

# Install Python integrations first; the OCR package can rely on other
# Python-level tooling. Shared helper tries arch_lib, then builds from AUR
# as the non-root builder and installs the resulting packages via sudo.
ensure_aur_deps \
    python-pdf2image \
    python-unoserver \
    ocrmypdf

# Ensure makepkg will not fail with "target not found" for these names.
missing=()
for dep in python-pdf2image python-unoserver ocrmypdf; do
    if ! pacman -T "$dep" >/dev/null 2>&1; then
        missing+=("$dep")
    fi
done
if (( ${#missing[@]} > 0 )); then
    printf '  [hook] Unresolved Stirling PDF dependencies: %s\n' "${missing[*]}" >&2
    exit 1
fi

echo "  [hook] Stirling PDF AUR-only runtime dependencies ready"
