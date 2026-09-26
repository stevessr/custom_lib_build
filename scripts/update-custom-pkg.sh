#!/usr/bin/env bash
# Update a custom package whose PKGBUILD tracks a stable GitHub release.
#
# Usage: update-custom-pkg.sh <sparkle-bin|cherry-studio-bin|claude-desktop-http-patch|claude-desktop-full-patch>
# The script updates the recipe in place and emits `version` and `changed`
# through GITHUB_OUTPUT when running in GitHub Actions.
set -euo pipefail

PKG="${1:-}"
ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PKGBUILD="$ROOT/custom-pkgs/$PKG/PKGBUILD"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "::error::$*" >&2
  exit 1
}

emit() {
  local key="$1" value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

# ── claude-desktop-*-patch：版本来自 Anthropic 官方 apt 索引 ───────────────
# 这两个 PKGBUILD 的 pkgver()/校验和在构建时动态获取，这里只把静态的
# pkgver= 行同步到最新版本，让仓库里的 recipe 与实际构建结果一致。
update_claude_desktop_patch() {
  [ -f "$PKGBUILD" ] || fail "missing PKGBUILD: $PKGBUILD"
  local apt='https://downloads.claude.ai/claude-desktop/apt/stable'
  local arch latest amd64_ver arm64_ver
  for arch in amd64 arm64; do
    latest="$(curl -fsSL --max-time 60 --retry 5 --retry-all-errors --retry-delay 3 \
        "$apt/dists/stable/main/binary-$arch/Packages" \
      | awk -v RS= -v FS='\n' '{ for (i=1;i<=NF;i++) if ($i ~ /^Version: /) print substr($i,10) }' \
      | sort -V | tail -n1)"
    [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "cannot read latest $arch version from apt index"
    if [ "$arch" = amd64 ]; then amd64_ver="$latest"; else arm64_ver="$latest"; fi
  done
  # 两个架构偶尔不同步；以两个架构都已发布的较低版本为准，避免 aarch64 构建失败
  local version="$amd64_ver"
  if [ "$(printf '%s\n%s\n' "$amd64_ver" "$arm64_ver" | sort -V | head -n1)" != "$amd64_ver" ]; then
    version="$arm64_ver"
  fi

  local current_version
  current_version="$(sed -nE "s/^pkgver[[:space:]]*=[[:space:]]*[\"']?([^\"']+)[\"']?[[:space:]]*$/\1/p" "$PKGBUILD" | sed -n '1p')"
  [ -n "$current_version" ] || fail "could not read pkgver from $PKGBUILD"

  echo "$PKG: current=$current_version latest=$version (amd64=$amd64_ver arm64=$arm64_ver)"
  emit version "$version"
  if [ "$current_version" = "$version" ]; then
    emit changed false
    echo "$PKG is already up to date"
    exit 0
  fi

  sed -i -E "s/^pkgver=.*$/pkgver=$version/; s/^pkgrel=.*$/pkgrel=1/" "$PKGBUILD"
  bash -n "$PKGBUILD"
  emit changed true
  echo "$PKG updated to $version"
  exit 0
}

case "$PKG" in
  claude-desktop-http-patch|claude-desktop-full-patch)
    update_claude_desktop_patch
    ;;
  sparkle-bin)
    REPOSITORY='xishang0128/sparkle'
    AMD64_ASSET='sparkle-linux-%s-amd64.deb'
    ARM64_ASSET='sparkle-linux-%s-arm64.deb'
    ;;
  cherry-studio-bin)
    REPOSITORY='CherryHQ/cherry-studio'
    # 源用上游 RPM（AppImage 的 squashfs 已压缩，进 tar.zst 后几乎不再
    # 缩；RPM payload 可再压 ~90 MB）。文件名同 AppImage 布局：linux-x64 /
    # linux-arm64，无 CN 变体后缀。
    AMD64_ASSET='Cherry-Studio-%s-linux-x64.rpm'
    ARM64_ASSET='Cherry-Studio-%s-linux-arm64.rpm'
    ;;
  *)
    fail "unsupported custom package: ${PKG:-<empty>}"
    ;;
esac

[ -f "$PKGBUILD" ] || fail "missing PKGBUILD: $PKGBUILD"

release_json="$TMP_DIR/release.json"
curl -fsSL --max-time 30 --retry 5 --retry-all-errors --retry-delay 3 \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "https://api.github.com/repos/$REPOSITORY/releases/latest" \
  -o "$release_json"

latest_tag="$(jq -r '.tag_name // empty' "$release_json")"
[ -n "$latest_tag" ] || fail "GitHub release has no tag: $REPOSITORY"
version="${latest_tag#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "unsupported stable release tag '$latest_tag' for $REPOSITORY"

current_version="$(sed -nE "s/^pkgver[[:space:]]*=[[:space:]]*[\"']?([^\"']+)[\"']?[[:space:]]*$/\1/p" "$PKGBUILD" | sed -n '1p')"
[ -n "$current_version" ] || fail "could not read pkgver from $PKGBUILD"

echo "$PKG: current=$current_version latest=$version"
emit version "$version"

if [ "$current_version" = "$version" ]; then
  emit changed false
  echo "$PKG is already up to date"
  exit 0
fi

# The checksum is intentionally calculated from the upstream GitHub asset.
# The recipe continues to download from GitHub, so a changed mirror cannot
# silently produce a checksum for a different source.
download_asset() {
  local asset="$1" output="$2"
  local url="https://github.com/$REPOSITORY/releases/download/$latest_tag/$asset"
  curl -fsSL --max-time 600 --retry 5 --retry-all-errors --retry-delay 5 \
    -o "$output" "$url"
  [ -s "$output" ] || fail "empty release asset: $asset"
}

printf -v amd64_asset "$AMD64_ASSET" "$version"
printf -v arm64_asset "$ARM64_ASSET" "$version"
download_asset "$amd64_asset" "$TMP_DIR/amd64"
download_asset "$arm64_asset" "$TMP_DIR/arm64"

amd64_sha256="$(sha256sum "$TMP_DIR/amd64" | cut -d' ' -f1)"
arm64_sha256="$(sha256sum "$TMP_DIR/arm64" | cut -d' ' -f1)"
[[ "$amd64_sha256" =~ ^[[:xdigit:]]{64}$ ]] || fail "invalid amd64 checksum"
[[ "$arm64_sha256" =~ ^[[:xdigit:]]{64}$ ]] || fail "invalid arm64 checksum"

PKG="$PKG" PKGBUILD_PATH="$PKGBUILD" VERSION="$version" \
  AMD64_SHA256="$amd64_sha256" ARM64_SHA256="$arm64_sha256" \
  python3 - <<'PY'
import os
from pathlib import Path

pkg = os.environ["PKG"]
path = Path(os.environ["PKGBUILD_PATH"])
version = os.environ["VERSION"]
amd64 = os.environ["AMD64_SHA256"]
arm64 = os.environ["ARM64_SHA256"]
text = path.read_text(encoding="utf-8")

if pkg == "sparkle-bin":
    replacements = [
        (r'(?m)^pkgver=["\']?[0-9]+\.[0-9]+\.[0-9]+["\']?$', f'pkgver="{version}"'),
        (r"(?m)^sha256sums=\('[0-9a-fA-F]{64}'\)$", f"sha256sums=('{amd64}')"),
        (r"(?m)^sha256sums_aarch64=\('[0-9a-fA-F]{64}'\)$", f"sha256sums_aarch64=('{arm64}')"),
    ]
elif pkg == "cherry-studio-bin":
    replacements = [
        (r'(?m)^pkgver=["\']?[0-9]+\.[0-9]+\.[0-9]+["\']?$', f'pkgver={version}'),
        # case 块内行序可能变化（_rpm_arch 行在前），按 arch 分支锚定
        (r"(?ms)(^  x86_64\)\n(?:(?!  aarch64\)).)*?    _sha256sum=')[0-9a-fA-F]{64}(')",
         rf"\g<1>{amd64}\g<2>"),
        (r"(?ms)(^  aarch64\)\n(?:(?!  x86_64\)).)*?    _sha256sum=')[0-9a-fA-F]{64}(')",
         rf"\g<1>{arm64}\g<2>"),
    ]
else:
    raise SystemExit(f"unsupported package: {pkg}")

import re
for replacement in replacements:
    pattern, value, *expected = replacement
    count = expected[0] if expected else 1
    text, found = re.subn(pattern, value, text, count=count)
    if found != count:
        raise SystemExit(f"expected {count} replacement(s) for {pattern!r}, found {found}")

path.write_text(text, encoding="utf-8", newline="\n")
PY

bash -n "$PKGBUILD"
emit changed true
echo "$PKG updated to $version (amd64=$amd64_sha256 arm64=$arm64_sha256)"
