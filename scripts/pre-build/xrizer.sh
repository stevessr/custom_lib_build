#!/bin/bash
set -euo pipefail
# xrizer compiles an i686 OpenXR SDK build. x86_64 gcc-libs alone do not
# contain the 32-bit libgcc_s.so.1 required at CMake's linker probe.
sudo pacman -S --noconfirm --needed lib32-gcc-libs lib32-glibc
if command -v rustup >/dev/null 2>&1; then
    rustup set profile minimal
    rustup toolchain install stable --profile minimal --no-self-update
    rustup default stable
    rustup target add i686-unknown-linux-gnu
fi
