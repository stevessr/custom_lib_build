#!/bin/bash
set -euo pipefail

# python-conda has several AUR-only runtime dependencies. Build them in a
# dependency-safe order so the first repository build can bootstrap itself;
# subsequent runs normally install them directly from arch_lib/latest.
source "$GITHUB_WORKSPACE/scripts/pre-build/aur-deps-lib.sh"

ensure_aur_deps \
    python-archspec \
    python-boltons \
    python-conda-package-streaming \
    python-conda-package-handling \
    micromamba \
    python-conda-libmamba-solver
