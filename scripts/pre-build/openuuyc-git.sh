#!/bin/bash
set -euo pipefail
# AUR rustup provides 'rust' and 'cargo' but has no default toolchain when
# installed into a fresh builder account. Select stable before building the
# Linux-port workspace, including its VKMS helper crate.
if command -v rustup >/dev/null 2>&1; then
    rustup set profile minimal
    rustup toolchain install stable --profile minimal
    rustup default stable
fi
