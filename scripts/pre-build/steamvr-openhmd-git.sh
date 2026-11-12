#!/bin/bash
set -euo pipefail

dir="${1:?PKGBUILD directory required}"
recipe="$dir/PKGBUILD"
[ -f "$recipe" ]

if grep -q -- '-DCMAKE_POLICY_VERSION_MINIMUM=3.5' "$recipe"; then
    exit 0
fi
if ! grep -q 'cmake -DCMAKE_INSTALL_PREFIX=' "$recipe"; then
    echo "steamvr-openhmd-git PKGBUILD no longer has the expected CMake command" >&2
    exit 1
fi
sed -i 's/cmake -DCMAKE_INSTALL_PREFIX=/cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_INSTALL_PREFIX=/' "$recipe"
