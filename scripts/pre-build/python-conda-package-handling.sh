#!/bin/bash
set -euo pipefail

source "$GITHUB_WORKSPACE/scripts/pre-build/aur-deps-lib.sh"

# AUR-only runtime dependency of python-conda-package-handling.
ensure_aur_deps python-conda-package-streaming
