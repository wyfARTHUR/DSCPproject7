#!/usr/bin/env python3
"""Check every tracked monthly CSV against the dataset manifest (Python 3.9+)."""
import hashlib
import json
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / 'data' / 'manifest.json').read_text(encoding='utf-8'))
    for index, entry in enumerate(manifest['files'], 1):
        path = root / 'data' / entry['path']
        sha = hashlib.sha256()
        with path.open('rb') as stream:
            while chunk := stream.read(4*1024*1024):
                sha.update(chunk)
        if path.stat().st_size != entry['bytes'] or sha.hexdigest() != entry['sha256']:
            raise RuntimeError(f'CSV size/checksum mismatch: {path}')
        if index % 12 == 0 or index == len(manifest['files']):
            print(f'Verified {index}/{len(manifest["files"])} CSV files', flush=True)
    print(f'All files verified. Dataset contains {manifest["source"]["rows"]:,} data rows.')


if __name__ == '__main__':
    main()
