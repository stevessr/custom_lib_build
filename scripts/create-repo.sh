#!/bin/bash
#
# create-repo.sh — Create pacman repository database from built packages
#
# Runs AFTER all matrix build jobs finish. Collects all .pkg.tar.* files
# from artifacts, runs repo-add, and produces the final repos/ tree.
#
set -euo pipefail

REPO_NAME="arch_lib"
REPO_DIR="repos/x86_64"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
LAST_VERSIONS_FILE="$WORKSPACE/last-versions.txt"
NEW_VERSIONS_FILE="$WORKSPACE/new-versions.txt"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

mkdir -p "$REPO_DIR"

# ── Collect all packages from artifact directory ─────────────────────
ARTIFACT_DIR="$WORKSPACE/packages-artifact"
if [ -d "$ARTIFACT_DIR" ]; then
    echo -e "${YELLOW}Collecting packages from artifact...${NC}"
    find "$ARTIFACT_DIR" -name '*.pkg.tar.*' -exec cp -t "$REPO_DIR" {} +
fi

# ── Build last-versions.txt from previous release and new builds ─────
echo -e "${YELLOW}Recording versions...${NC}"

# Start with previously known versions (if any)
: > "$NEW_VERSIONS_FILE"

# Merge version info: first load last known, then overlay new builds
if [ -f "$LAST_VERSIONS_FILE" ]; then
    cat "$LAST_VERSIONS_FILE" > "$NEW_VERSIONS_FILE"
fi

# Overlay versions supplied via GITHUB_OUTPUT-style key=value pairs
VERSIONS_FILE="$WORKSPACE/build-versions.txt"
if [ -f "$VERSIONS_FILE" ]; then
    while IFS='=' read -r pkg ver; do
        [ -n "$pkg" ] || continue
        # Replace or append
        if grep -q "^${pkg}=" "$NEW_VERSIONS_FILE" 2>/dev/null; then
            sed -i "s/^${pkg}=.*/${pkg}=${ver}/" "$NEW_VERSIONS_FILE"
        else
            echo "${pkg}=${ver}" >> "$NEW_VERSIONS_FILE"
        fi
    done < "$VERSIONS_FILE"
fi

# ── Create repository database ───────────────────────────────────────
cd "$REPO_DIR"

PKG_COUNT=$(ls -1 *.pkg.tar.* 2>/dev/null | wc -l || true)
if [ "$PKG_COUNT" -eq 0 ]; then
    echo -e "${RED}No packages to add to repository${NC}"
    exit 1
fi

echo -e "${YELLOW}Creating repository database ($PKG_COUNT packages)...${NC}"

# Clean previous database
rm -f "$REPO_NAME.db.tar.gz" "$REPO_NAME.db" \
      "$REPO_NAME.files.tar.gz" "$REPO_NAME.files"

# Build new database
repo-add --remove --new "$REPO_NAME.db.tar.gz" ./*.pkg.tar.* 2>&1 | sed 's/^/  /'

# Symlinks for pacman compatibility
ln -sf "$REPO_NAME.db.tar.gz" "$REPO_NAME.db" 2>/dev/null || true
ln -sf "$REPO_NAME.files.tar.gz" "$REPO_NAME.files" 2>/dev/null || true

# ── Write versions file for next run ─────────────────────────────────
cd "$WORKSPACE"
cp "$NEW_VERSIONS_FILE" last-versions.txt

# ── Summary ──────────────────────────────────────────────────────────
echo -e "${GREEN}✓ Repository database created${NC}"
echo ""
echo "Contents:"
ls -lh "$REPO_DIR/" 2>/dev/null | sed 's/^/  /'
echo ""
echo "Versions recorded:"
cat last-versions.txt | sed 's/^/  /'