#!/bin/bash
set -euo pipefail
# OCRmyPDF's AUR recipe requires python-fpdf2, which is not in Arch extra.
# Bootstrap it before makepkg -s resolves dependency names.
source "$GITHUB_WORKSPACE/scripts/pre-build/aur-deps-lib.sh"
ensure_aur_deps python-fpdf2
