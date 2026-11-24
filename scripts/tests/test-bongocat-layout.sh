#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$root/custom-pkgs/bongocat-bin/PKGBUILD"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for layout in flat nested bin; do
  (
    srcdir="$tmp/$layout/src"; pkgdir="$tmp/$layout/pkg"
    mkdir -p "$srcdir" "$pkgdir" "$tmp/$layout/input"
    input="$tmp/$layout/input"
    case "$layout" in
      flat) runtime="$input"; binary=BongoCat ;;
      nested) runtime="$input/different-release-directory"; binary=bongo-cat ;;
      bin) runtime="$input/another-root"; binary=bin/bongo_cat ;;
    esac
    mkdir -p "$runtime/assets" "$runtime/share/applications" "$(dirname "$runtime/$binary")"
    cp /bin/true "$runtime/$binary"
    chmod 644 "$runtime/$binary"
    printf 'asset\n' > "$runtime/assets/test.txt"
    printf '[Desktop Entry]\nExec=BongoCat %%U\n' > "$runtime/share/applications/bongo-cat.desktop"
    if [[ $layout == nested ]]; then
      archive="$tmp/$layout/archive.tar.gz"
      tar -czf "$archive" -C "$input" .
    else
      archive="$tmp/$layout/archive.zip"
      (cd "$input" && zip -qr "$archive" .)
    fi
    _bongocat_unpack "$archive" "$srcdir/.bongocat-extracted"
    package
    test -x "$pkgdir/usr/lib/bongocat-bin/$binary"
    test -f "$pkgdir/usr/lib/bongocat-bin/assets/test.txt"
    grep -Fx 'Exec=bongocat %U' "$pkgdir/usr/share/applications/bongo-cat.desktop"
    grep -Fx "exec /usr/lib/bongocat-bin/$binary \"\$@\"" "$pkgdir/usr/bin/bongocat"
    test ! -e "$pkgdir/usr/lib/bongocat-bin/.runtime-root"
    echo "PASS: $layout"
  )
done
mkdir -p "$tmp/bad"
printf 'not ELF\n' > "$tmp/bad/BongoCat"
(cd "$tmp/bad" && zip -q "$tmp/bad.zip" BongoCat)
if _bongocat_unpack "$tmp/bad.zip" "$tmp/bad-stage"; then
  echo 'Non-ELF archive unexpectedly accepted' >&2; exit 1
fi
cp /bin/true "$tmp/bad/BongoCat"
cp /bin/true "$tmp/bad/bongo-cat"
(cd "$tmp/bad" && zip -q "$tmp/ambiguous.zip" BongoCat bongo-cat)
if _bongocat_unpack "$tmp/ambiguous.zip" "$tmp/bad-stage"; then
  echo 'Ambiguous archive unexpectedly accepted' >&2; exit 1
fi
echo 'PASS: malformed and ambiguous archives rejected'
