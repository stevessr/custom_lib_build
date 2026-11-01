#!/usr/bin/env python3
"""Compare pacman repo database with GitHub Release asset metadata.

Usage: python arch_release_audit.py DB.TAR.GZ ASSETS.JSONL REPORT.JSON
"""
import json
import sys
import tarfile
from pathlib import Path


def parse_desc(raw):
    fields = {}
    key = None
    for line in raw.decode('utf-8').splitlines():
        if line.startswith('%') and line.endswith('%'):
            key = line.strip('%')
        elif key and line.strip():
            fields.setdefault(key, []).append(line.strip())
    return {key: value[0] for key, value in fields.items() if value}


def main():
    if len(sys.argv) != 4:
        raise SystemExit('Usage: audit.py DB.TAR.GZ ASSETS.JSONL REPORT.JSON')
    db, assets_file, report_file = sys.argv[1:]
    assets = {}
    for line in Path(assets_file).read_text().splitlines():
        asset = json.loads(line)
        assets[asset['name']] = asset
    mismatches = []
    indexed = 0
    with tarfile.open(db, mode='r:gz') as tf:
        for member in tf:
            if not member.name.endswith('/desc'):
                continue
            fields = parse_desc(tf.extractfile(member).read())
            name = fields.get('FILENAME')
            if not name:
                raise ValueError(f'Missing FILENAME: {member.name}')
            indexed += 1
            asset = assets.get(name)
            reasons = []
            if asset is None:
                reasons.append('asset_missing')
            else:
                recorded_size = fields.get('CSIZE')
                if recorded_size is None or int(recorded_size) != asset['size']:
                    reasons.append('size_mismatch')
                recorded_sha = fields.get('SHA256SUM')
                digest = asset.get('digest') or ''
                if digest.startswith('sha256:') and recorded_sha and digest[7:].lower() != recorded_sha.lower():
                    reasons.append('sha256_mismatch')
            if reasons:
                mismatches.append({'filename': name, 'name': fields.get('NAME'), 'version': fields.get('VERSION'), 'arch': fields.get('ARCH'), 'reasons': reasons})
    if not indexed:
        raise ValueError('Empty repo database')
    report = {'indexed': indexed, 'assets': len(assets), 'mismatches': mismatches}
    Path(report_file).write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(f'Indexed: {indexed}; Release assets: {len(assets)}; mismatch entries: {len(mismatches)}')
    for item in mismatches:
        print(item['filename'] + ': ' + ','.join(item['reasons']))


if __name__ == '__main__':
    main()
