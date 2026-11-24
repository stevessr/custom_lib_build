#!/bin/bash
set -euo pipefail
# Fix the never-type fallback regression in ashpd 0.8.1 without changing its API.
alvr_dir="${1:?ALVR source directory required}"
source_root="$(dirname "$alvr_dir")"
crate_sha=$(python - "$alvr_dir/Cargo.lock" <<'PY'
import sys,tomllib
with open(sys.argv[1],'rb') as f:
    lock=tomllib.load(f)
pkg=[p for p in lock['package'] if p['name']=='ashpd' and p['version']=='0.8.1']
if len(pkg)!=1 or not pkg[0].get('checksum'):
    raise SystemExit('Expected exactly one locked ashpd 0.8.1 registry crate')
print(pkg[0]['checksum'])
PY
)
crate="$source_root/ashpd-0.8.1.crate"
source_dir="$source_root/ashpd-0.8.1"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://static.crates.io/crates/ashpd/ashpd-0.8.1.crate" -o "$crate.part"
echo "$crate_sha  $crate.part" | sha256sum -c --status || {
    rm -f "$crate.part"
    echo "ALVR ashpd crate SHA256 mismatch" >&2
    exit 1
}
mv "$crate.part" "$crate"
rm -rf "$source_dir"
bsdtar -xf "$crate" -C "$source_root"
python - "$source_dir/src/desktop/clipboard.rs" "$alvr_dir/Cargo.toml" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text()
old='self.0.call("SetSelection", &(session, options)).await?;'
new='self.0.call::<()>("SetSelection", &(session, options)).await?;'
if s.count(old)!=1:
    raise SystemExit('Unable to locate ashpd SetSelection call')
p.write_text(s.replace(old,new))
p=Path(sys.argv[2])
s=p.read_text()
header=re.compile(r'^\[patch\.crates-io\][ \t]*$', re.M)
if len(header.findall(s))!=1:
    raise SystemExit('Expected one existing ALVR patch.crates-io table')
s=header.sub('[patch.crates-io]\nashpd = { path = "../ashpd-0.8.1" }',s,count=1)
p.write_text(s)
PY
(
    cd "$alvr_dir"
    cargo update -p ashpd@0.8.1
    cargo fetch --locked
    cargo metadata --locked --format-version 1 --no-deps >/dev/null
)
echo "[ALVR] Patched ashpd 0.8.1 SetSelection reply type"
