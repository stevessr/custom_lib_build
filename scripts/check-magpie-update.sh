#!/usr/bin/env bash
# Compare upstream Magpie's latest release with both published package markers.
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

upstream_tag="$(gh api repos/yetone/magpie-releases/releases/latest --jq '.tag_name // empty')"
version="${upstream_tag#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::Invalid latest Magpie release tag: ${upstream_tag:-<empty>}" >&2
  exit 1
fi

echo "Upstream tag: $upstream_tag → version: $version"

metadata_file="$(mktemp)"
trap 'rm -f "$metadata_file"' EXIT
changed=false
for package in magpie-bin magpie-cli-bin; do
  url="https://github.com/${GITHUB_REPOSITORY}/releases/download/latest/version-${package}.txt"
  status="$(curl -sSL --max-time 30 --retry 5 --retry-all-errors --retry-delay 2 \
    -o "$metadata_file" -w '%{http_code}' "$url")"
  case "$status" in
    200)
      published="$(tr -d '[:space:]' < "$metadata_file")"
      ;;
    404)
      published=""
      ;;
    *)
      echo "::error::Unable to read published version for $package (HTTP $status)" >&2
      exit 1
      ;;
  esac

  echo "$package published version: ${published:-<none>}"
  if [[ "$version" != "$published" ]]; then
    changed=true
  fi
done

printf 'changed=%s\nversion=%s\n' "$changed" "$version" >> "$GITHUB_OUTPUT"
if [[ "$changed" == true ]]; then
  echo "Magpie release changed or package metadata is missing — build both packages."
else
  echo "Both published Magpie packages are current."
fi
