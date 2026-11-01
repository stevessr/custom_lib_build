#!/bin/bash
set -euo pipefail
alvr_dir="${1:?ALVR source directory required}"
source_root="$(dirname "$alvr_dir")"
test -f "$alvr_dir/Cargo.lock" && test -f "$alvr_dir/Cargo.toml" || {
    echo "ALVR source Cargo.lock/Cargo.toml missing at $alvr_dir" >&2
    exit 1
}
# Check source checksum against Cargo.lock-pinned libspa-sys.
crate_sha=$(python - "$alvr_dir/Cargo.lock" <<'PY'
import sys,tomllib
with open(sys.argv[1],'rb') as f:
    lock=tomllib.load(f)
pkg=[p for p in lock['package'] if p['name']=='libspa-sys' and p['version']=='0.8.0']
if len(pkg)!=1 or not pkg[0].get('checksum'):
    raise SystemExit('Expected exactly one locked libspa-sys 0.8.0 registry crate')
print(pkg[0]['checksum'])
PY
)
crate="$source_root/libspa-sys-0.8.0.crate"
source_dir="$source_root/libspa-sys-0.8.0"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://static.crates.io/crates/libspa-sys/libspa-sys-0.8.0.crate" -o "$crate.part"
echo "$crate_sha  $crate.part" | sha256sum -c --status || {
    rm -f "$crate.part"
    echo "ALVR libspa-sys crate SHA256 mismatch" >&2
    exit 1
}
mv "$crate.part" "$crate"
rm -rf "$source_dir"
bsdtar -xf "$crate" -C "$source_root"
test -f "$source_dir/Cargo.toml" || { echo 'libspa-sys source missing Cargo.toml' >&2; exit 1; }
python - "$source_dir/Cargo.toml" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text()
pattern=r'(\[build-dependencies\.bindgen\]\s*\n\s*version\s*=\s*")[^"]+(")'
s2,n=re.subn(pattern,r'\g<1>0.72.1\2',s)
if n!=1:
    raise SystemExit('Unable to locate pinned bindgen version in libspa-sys')
p.write_text(s2)
PY
if grep -q '^\[patch.crates-io\]' "$alvr_dir/Cargo.toml"; then
    echo "ALVR upstream already declares [patch.crates-io]; refusing conflicting patch" >&2
    exit 1
fi
printf '\n[patch.crates-io]\nlibspa-sys = { path = "../libspa-sys-0.8.0" }\n' >> "$alvr_dir/Cargo.toml"
(
    cd "$alvr_dir"
    cargo update -p libspa-sys@0.8.0
    cargo metadata --locked --format-version 1 --no-deps >/dev/null
)
echo "[ALVR] Patched libspa-sys 0.8.0 to bindgen 0.72.1 (PipeWire enabled)"
