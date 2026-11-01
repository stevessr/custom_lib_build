#!/bin/bash
set -euo pipefail
dir="${1:?Python C++ grammar PKGBUILD directory required}"
recipe="$dir/PKGBUILD"
test -f "$recipe"
# The Python grammar embeds its native implementation and does not require
# a separate tree-sitter-cpp=0.23.4 system package.
python3 - "$recipe" <<'PY'
import re,sys
from pathlib import Path
p=Path(sys.argv[1])
s=p.read_text()
pattern=r"""(['"])tree-sitter-cpp=0\.23\.4\1"""
s2,n=re.subn(pattern,'',s)
if n!=1:
    raise SystemExit(f'Expected exactly one native grammar dependency, found {n}')
p.write_text(s2+'\n# arch_lib: remove erroneous duplicate native grammar dependency\npkgrel=$((pkgrel+1))\n')
PY
bash -n "$recipe"
echo "[hook] Python C++ grammar: native system dependency removed, Python binding retained"
