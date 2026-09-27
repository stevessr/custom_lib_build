#!/bin/bash
set -euo pipefail

# vcstool 0.3.0 still imports pkg_resources in commands/help.py. It was
# removed from setuptools >= 82 (Arch Python 3.14), so even "vcs --help"
# crashes. Patch the staged package, not /usr/lib or the global Python env.
#
# This hook is run for both AUR bootstrap and the regular package matrix.
# Preserve upstream package() and patch the installed file after it runs.
dir="$1"
test -f "$dir/PKGBUILD" || { echo "[hook] python-vcstool PKGBUILD missing" >&2; exit 1; }

# Do not append the wrapper twice if a cached working tree is reused.
if grep -q '^# BEGIN arch_lib vcstool compatibility patch$' "$dir/PKGBUILD"; then
    exit 0
fi

cat >> "$dir/PKGBUILD" <<'PKGBUILD_PATCH'

# BEGIN arch_lib vcstool compatibility patch
# Local packaging fix: replace the obsolete pkg_resources entry-point loader
# with the Python stdlib equivalent in the installed wheel/package.
pkgrel=$((pkgrel + 1))

if ! declare -f package >/dev/null; then
    echo "python-vcstool: upstream PKGBUILD has no package() to wrap" >&2
    exit 1
fi
eval "$(declare -f package | sed '1s/^package[[:space:]]*()/_vcstool_original_package ()/')"

package() {
    _vcstool_original_package || return 1
    python3 - "$pkgdir" <<'PY' || return 1
from pathlib import Path
import sys

root = Path(sys.argv[1])
matches = list(root.glob('usr/lib/python*/site-packages/vcstool/commands/help.py'))
if len(matches) != 1:
    raise SystemExit(f"Expected exactly one packaged vcstool help.py, found {matches}")
path = matches[0]
old = "from pkg_resources import load_entry_point"
new = """from importlib.metadata import distribution


def load_entry_point(dist_name, group, name):
    # Scope lookup to vcstool's own distribution, as pkg_resources did.
    for entry in distribution(dist_name).entry_points:
        if entry.group == group and entry.name == name:
            return entry.load()
    raise LookupError(f"No entry point {group}:{name} in {dist_name}")
"""
content = path.read_text()
if content.count(old) != 1:
    raise SystemExit(f"Expected one legacy pkg_resources import in {path}")
path.write_text(content.replace(old, new, 1))
compile(path.read_text(), str(path), "exec")
print(f"  [hook] Patched packaged vcstool entry-point loader: {path}")
PY
}
# END arch_lib vcstool compatibility patch
PKGBUILD_PATCH

# Confirm the appended shell wrapper parses before spending time on makepkg.
bash -n "$dir/PKGBUILD"
echo "  [hook] Prepared python-vcstool package compatibility patch"
