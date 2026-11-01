#!/bin/bash
set -euo pipefail
# The image ships rustup proxies without a default user toolchain.
# Set up the toolchain as 'builder', not root, before makepkg calls cargo.
if command -v rustup >/dev/null 2>&1; then
    rustup set profile minimal
    rustup toolchain install stable --profile minimal
    rustup default stable
    rustc --version
    cargo --version
fi
