#!/bin/bash
set -euo pipefail

# portable currently needs portable-packer from the AUR during build. Bootstrap
# that makedep before makepkg so the package can be built on a clean runner.
source "$GITHUB_WORKSPACE/scripts/pre-build/aur-deps-lib.sh"

ensure_aur_deps portable-packer
