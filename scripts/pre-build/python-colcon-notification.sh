#!/bin/bash
set -euo pipefail

# python-colcon-notification (bootstrap dependency of ros2-kilted, and a
# custom matrix package) needs python-colcon-core, which is AUR-only and
# missing from official repos on a fresh runner. Bootstrap it here so
# makepkg -s can resolve, and patch the pkg_resources check out of the
# pinned 0.3.0 setup.py (setuptools >= 81 removed pkg_resources).
source "$GITHUB_WORKSPACE/scripts/pre-build/aur-deps-lib.sh"

ensure_aur_deps python-colcon-core

dir="${1:?dependency source dir required}"
setup_py="$dir/colcon-notification-0.3.0/setup.py"

if [ -f "$setup_py" ] && grep -q "pkg_resources" "$setup_py"; then
    # Delete the whole conditional pkg_resources version check (from its
    # `if 'BUILD_DEBIAN_PACKAGE'` line through the matching `sys.exit(1)`),
    # keeping the cmdclass lines that follow.
    python3 - "$setup_py" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).readlines()
out, skip = [], False
for ln in lines:
    if not skip and "'BUILD_DEBIAN_PACKAGE' not in os.environ" in ln:
        skip = True
        continue
    if skip:
        if "sys.exit(1)" in ln:
            skip = False
        continue
    out.append(ln)
open(p, "w").writelines(out)
PY
    echo "  [hook] patched pkg_resources check out of $setup_py"
fi
