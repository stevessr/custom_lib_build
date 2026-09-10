#!/bin/bash
set -euo pipefail

source "$GITHUB_WORKSPACE/scripts/pre-build/aur-deps-lib.sh"

# The AUR micromamba package provides python-libmambapy, which is required by
# python-conda-libmamba-solver. micromamba-bin intentionally does not provide
# that Python binding, so the full micromamba package is required here.
ensure_aur_deps micromamba
