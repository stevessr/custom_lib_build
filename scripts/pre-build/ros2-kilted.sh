#!/bin/bash
set -euo pipefail

# ros2-kilted (AUR) declares dependencies that no longer exist in the
# official repos and that pacman cannot resolve at makepkg -s time:
#   - python-colcon-common-extensions (AUR meta; depends the colcon suite)
#   - sip4 / python-sip4              (AUR; extra only has sip 6.x)
#   - lttng-tools                     (AUR; extra only has lttng-ust)
# Order matters: pacman resolves `makepkg -s` deps only from configured
# repos, so every AUR-only package must be installed before anything that
# depends on it. The colcon meta package's makepkg -s pulls the whole
# suite, so build it in this exact order:
#   1. colcon-core's own AUR-only deps (python-empy3, python-pytest-runner)
#   2. python-colcon-core
#   3. python-colcon-ros' own subpackage deps (library-path, cmake,
#      pkg-config, recursive-crawl, python-setup-py — all depend only core)
#   4. python-colcon-ros
#   5. the remaining 10 subpackages (depends only core) + the meta package
# sip4 is one split package producing both sip4 and python-sip4.
source "$GITHUB_WORKSPACE/scripts/pre-build/aur-deps-lib.sh"

ensure_aur_deps \
    python-empy3 \
    python-pytest-runner \
    python-colcon-core \
    python-colcon-library-path \
    python-colcon-cmake \
    python-colcon-pkg-config \
    python-colcon-recursive-crawl \
    python-colcon-python-setup-py \
    python-catkin_pkg \
    python-colcon-ros \
    python-colcon-metadata \
    python-colcon-argcomplete \
    python-colcon-notification \
    python-colcon-powershell \
    python-colcon-test-result \
    python-colcon-package-information \
    python-colcon-parallel-executor \
    python-colcon-bash \
    python-colcon-defaults \
    python-colcon-devtools \
    python-colcon-package-selection \
    python-colcon-output \
    python-colcon-zsh \
    python-colcon-common-extensions \
    sip4 \
    lttng-tools \
    python-rospkg \
    python-rosdistro \
    python-rosinstall_generator \
    python-vcstool

# Catch broken vcstool early (before ROS downloads/repository checkout).
# "vcs help import" exercises the command entry-point dispatcher as well as
# the main CLI import, unlike "vcs --version" alone.
if ! vcs help import >/dev/null 2>&1; then
    echo "  [hook] python-vcstool is installed but its CLI is unusable" >&2
    vcs help import >&2 || true
    exit 1
fi
echo "  [hook] ✓ vcstool command dispatcher works"
