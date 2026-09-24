#!/bin/bash
set -euo pipefail

PKG_DIR="${1:?package directory required}"
PKGBUILD="$PKG_DIR/PKGBUILD"

# portable-packer declares checkdepends=(portable), while portable itself
# depends on portable-packer. In an independently built binary repository this
# creates a bootstrap cycle only for check(); it is not a runtime dependency.
# Disable the package's check phase for the bootstrap/repository build.
sed -i -E \
  -e 's/^[[:space:]]*checkdepends=.*/checkdepends=()/' \
  -e 's/^([[:space:]]*)function[[:space:]]+check[[:space:]]*\(\)[[:space:]]*\{/\1function _arch_lib_check_disabled() {/' \
  -e 's/^([[:space:]]*)check[[:space:]]*\(\)[[:space:]]*\{/\1_arch_lib_check_disabled() {/' \
  "$PKGBUILD"

echo "  [hook] portable-packer: disabled circular portable check dependency"
