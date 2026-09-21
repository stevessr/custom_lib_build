#!/bin/bash
set -euo pipefail

# AUR wechat is a wrapper/sandbox package. Its hard runtime dependencies are
# also AUR packages, so bootstrap them here when arch_lib/latest does not yet
# contain them (for example on the first repository build).
source "$GITHUB_WORKSPACE/scripts/pre-build/aur-deps-lib.sh"

ensure_aur_deps \
    wechat-bin \
    portable
