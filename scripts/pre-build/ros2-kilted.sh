#!/bin/bash
set -euo pipefail

# ros2-kilted (AUR) declares dependencies that no longer exist in the
# official repos and that pacman cannot resolve at makepkg -s time:
#   - python-colcon-common-extensions (AUR meta, pulls the colcon suite)
#   - sip4 / python-sip4              (AUR; extra only has sip 6.x)
#   - lttng-tools                     (AUR; extra only has lttng-ust)
# Build them in a dependency-safe order so the first repository build can
# bootstrap itself; subsequent runs normally install them directly from
# arch_lib/latest.
source "$GITHUB_WORKSPACE/scripts/pre-build/aur-deps-lib.sh"

ensure_aur_deps \
    python-colcon-common-extensions \
    sip4 \
    python-sip4 \
    lttng-tools
