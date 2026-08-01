#!/bin/bash
# =============================================================================
# GC Releases — Clean up old releases of AUR packages on GitHub Releases
#
# Usage:
#   scripts/gc-releases.sh [package_name]
#
# If package_name is provided:
#   Cleans up old/duplicate releases for that specific package.
# If no argument is provided:
#   Cleans up old/duplicate releases for all packages listed in packages.txt.
#
# Requires:
#   - GH_TOKEN or GITHUB_TOKEN environment variable with contents:write permission
#   - curl and jq installed
# =============================================================================

set -euo pipefail

REPO="${GITHUB_REPOSITORY:-stevessr/custom_lib_build}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

if [ -z "$TOKEN" ]; then
  # Try falling back to gh auth token if available
  if command -v gh >/dev/null 2>&1; then
    TOKEN="$(gh auth token 2>/dev/null || true)"
  fi
fi

if [ -z "$TOKEN" ]; then
  echo "Error: GH_TOKEN or GITHUB_TOKEN is required for release GC"
  exit 1
fi

API_URL="https://api.github.com/repos/$REPO"

# Helper to fetch all releases across pages
fetch_all_releases() {
  local page=1
  local per_page=100
  local all_releases="[]"
  
  while true; do
    local res
    res=$(curl -fsSL -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "$API_URL/releases?per_page=$per_page&page=$page" 2>/dev/null || echo "[]")
    
    local count
    count=$(echo "$res" | jq '. | length' 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
      break
    fi
    
    all_releases=$(jq -s '.[0] + .[1]' <(echo "$all_releases") <(echo "$res"))
    
    if [ "$count" -lt "$per_page" ]; then
      break
    fi
    page=$((page + 1))
  done
  
  echo "$all_releases"
}

delete_release() {
  local release_id="$1"
  local tag_name="$2"
  local rel_name="$3"

  echo "  🗑 Deleting release #$release_id (tag: '$tag_name', name: '$rel_name')..."
  curl -fsSL -X DELETE -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$API_URL/releases/$release_id" || echo "  ⚠ Failed to delete release #$release_id"

  # Delete associated tag reference if tag_name is not empty
  if [ -n "$tag_name" ]; then
    curl -fsSL -X DELETE -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "$API_URL/git/refs/tags/$tag_name" >/dev/null 2>&1 || true
  fi
}

echo "Fetching all releases for $REPO..."
RELEASES_JSON=$(fetch_all_releases)
TOTAL_RELEASES=$(echo "$RELEASES_JSON" | jq '. | length')
echo "Found $TOTAL_RELEASES total release(s) on $REPO"

TARGET_PKG="${1:-}"

if [ -n "$TARGET_PKG" ]; then
  PACKAGES=("$TARGET_PKG")
else
  if [ -f packages.txt ]; then
    mapfile -t PACKAGES < <(
      sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' packages.txt \
        | grep -v '^$'
    )
  else
    echo "packages.txt not found and no package specified."
    exit 1
  fi
fi

DELETED_COUNT=0

for pkg in "${PACKAGES[@]}"; do
  # Match releases for this package:
  # Exclude special releases: "latest", "custom-keyring"
  # Match logic:
  # 1. tag_name == pkg
  # 2. tag_name matches ^pkg[-_@][vV]?[0-9]
  # 3. name matches ^pkg[ -][vV]?[0-9]
  matched=$(echo "$RELEASES_JSON" | jq -c --arg pkg "$pkg" '
    .[] | select(.tag_name != "latest" and .tag_name != "custom-keyring") |
    select(
      .tag_name == $pkg or
      (.tag_name | test("^" + ($pkg | gsub("[\\^\\$\\.\\*\\+\\?\\(\\)\\[\\]\\{\\}\\\\|]"; "\\\\$&")) + "[-_@][vV]?[0-9]")) or
      (.name | test("^" + ($pkg | gsub("[\\^\\$\\.\\*\\+\\?\\(\\)\\[\\]\\{\\}\\\\|]"; "\\\\$&")) + "[ -][vV]?[0-9]"))
    )
  ')

  count=$(echo "$matched" | grep -c '.' || true)
  if [ "$count" -le 1 ]; then
    continue
  fi

  echo "=== GC for package: $pkg ($count releases found) ==="

  # Sort matched releases by created_at descending (newest first)
  # The first item is kept, subsequent items are deleted
  sorted=$(echo "$matched" | jq -s 'sort_by(.created_at) | reverse')

  keep_info=$(echo "$sorted" | jq -r '.[0] | "\(.id) (tag: \(.tag_name), name: \(.name), date: \(.created_at))"')
  echo "  ✓ Keeping newest release: $keep_info"

  # Delete older releases
  old_releases=$(echo "$sorted" | jq -c '.[1:] | .[]')
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    rel_id=$(echo "$rel" | jq -r '.id')
    rel_tag=$(echo "$rel" | jq -r '.tag_name')
    rel_name=$(echo "$rel" | jq -r '.name')
    
    delete_release "$rel_id" "$rel_tag" "$rel_name"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  done <<< "$old_releases"
done

echo "GC complete. Cleaned up $DELETED_COUNT old release(s)."
