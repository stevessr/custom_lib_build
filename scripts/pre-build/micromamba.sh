#!/bin/bash
set -euo pipefail

source "$GITHUB_WORKSPACE/scripts/pre-build/aur-deps-lib.sh"

# reproc was moved out of the official Arch repositories but is still a
# runtime dependency of the AUR micromamba package.
ensure_aur_deps reproc
