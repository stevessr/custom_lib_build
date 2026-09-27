#!/bin/bash
set -euo pipefail

# pytest-runner 6.0.1 registers ptr:PyTest in setuptools' distutils.commands.
# Setuptools loads *every* such entry point during "setup.py --help-commands"
# even when pytest-runner is not used. Its eager pkg_resources import breaks
# that command since setuptools 82 removed pkg_resources.
#
# Patch the staged pacman package, not the global interpreter or system files.
# Keep the legacy command registered but replace the old metadata/marker APIs.
dir="$1"
test -f "$dir/PKGBUILD" || { echo "[hook] python-pytest-runner PKGBUILD missing" >&2; exit 1; }

if grep -q '^# BEGIN arch_lib pytest-runner compatibility patch$' "$dir/PKGBUILD"; then
    exit 0
fi

cat >> "$dir/PKGBUILD" <<'PKGBUILD_PATCH'

# BEGIN arch_lib pytest-runner compatibility patch
pkgrel=$((pkgrel + 1))
depends+=(python-packaging)

if ! declare -f package >/dev/null; then
    echo "python-pytest-runner: upstream PKGBUILD has no package() to wrap" >&2
    exit 1
fi
eval "$(declare -f package | sed '1s/^package[[:space:]]*()/_pytest_runner_original_package ()/')"

package() {
    _pytest_runner_original_package || return 1
    python3 - "$pkgdir" <<'PY' || return 1
from pathlib import Path
import sys

root = Path(sys.argv[1])
matches = list(root.glob('usr/lib/python*/site-packages/ptr/__init__.py'))
if len(matches) != 1:
    raise SystemExit(f"Expected exactly one packaged ptr/__init__.py: {matches}")
path = matches[0]
content = path.read_text()

replacements = [
    (
        "import pkg_resources\n",
        "from importlib.metadata import version as _distribution_version\n"
        "from packaging.markers import InvalidMarker, Marker\n"
        "from packaging.specifiers import SpecifierSet\n"
        "from packaging.version import parse as _parse_version\n",
    ),
    (
        "pkg_resources.require('setuptools>=27.3')",
        "if not SpecifierSet('>=27.3').contains(_distribution_version('setuptools')):\n"
        "            raise RuntimeError('pytest-runner requires setuptools>=27.3')",
    ),
    (
        "        return (\n"
        "            not marker\n"
        "            or not pkg_resources.invalid_marker(marker)\n"
        "            and pkg_resources.evaluate_marker(marker)\n"
        "        )",
        "        if not marker:\n"
        "            return True\n"
        "        try:\n"
        "            return Marker(marker).evaluate()\n"
        "        except InvalidMarker:\n"
        "            return False",
    ),
    (
        "pkg_resources.get_distribution('setuptools').version",
        "_distribution_version('setuptools')",
    ),
    ("pkg_resources.parse_version(", "_parse_version("),
]

for old, new in replacements:
    count = content.count(old)
    if count != 1 and not (old == "pkg_resources.parse_version(" and count == 2):
        raise SystemExit(f"Expected legacy API {old!r} exactly once (or twice for parse_version); found {count} in {path}")
    content = content.replace(old, new)
if "pkg_resources" in content:
    raise SystemExit(f"Unexpected remaining pkg_resources reference in {path}")
compile(content, str(path), "exec")
path.write_text(content)
print(f"  [hook] Patched packaged pytest-runner for modern setuptools: {path}")
PY
}
# END arch_lib pytest-runner compatibility patch
PKGBUILD_PATCH

bash -n "$dir/PKGBUILD"
echo "  [hook] Prepared python-pytest-runner package compatibility patch"
