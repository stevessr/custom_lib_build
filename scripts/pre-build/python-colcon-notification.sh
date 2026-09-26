#!/bin/bash
set -euo pipefail

# python-colcon-notification 0.3.0 (AUR, used as a bootstrap dependency of
# ros2-kilted) pins a setup.py that imports pkg_resources. Setuptools >= 81
# (current Arch, Python 3.14 runners) removed pkg_resources, so the wheel
# build dies with ModuleNotFoundError before its own version check can
# reject anything. The upstream main branch dropped the import; patch the
# pinned check out here. Runs before makepkg with cwd = the dependency
# source dir ($1, passed by install_aur_dep).
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
