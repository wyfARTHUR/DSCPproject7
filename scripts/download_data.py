#!/usr/bin/env python3
"""Download a yearly ZIP from this repository's dataset release and verify it."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--year', type=int, required=True)
    parser.add_argument('--output', type=Path, default=Path('data'))
    parser.add_argument('--extract', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    catalog = json.loads((root / 'data' / 'archives.json').read_text(encoding='utf-8'))
    entries = [x for x in catalog['archives'] if x['year'] == args.year]
    if len(entries) != 1:
        parser.error('Year is not present in the dataset catalog.')
    entry = entries[0]
    args.output.mkdir(parents=True, exist_ok=True)
    target = args.output / entry['filename']
    if not target.exists():
        temp = target.with_suffix('.zip.partial')
        request = urllib.request.Request(entry['url'], headers={'User-Agent': 'DSCPproject7-data-downloader'})
        with urllib.request.urlopen(request, timeout=120) as response, temp.open('wb') as stream:
            while chunk := response.read(4*1024*1024):
                stream.write(chunk)
        temp.replace(target)
    sha = hashlib.sha256()
    with target.open('rb') as stream:
        while chunk := stream.read(4*1024*1024):
            sha.update(chunk)
    if target.stat().st_size != entry['bytes'] or sha.hexdigest() != entry['sha256']:
        raise RuntimeError(f'Archive checksum/size mismatch: {target}. Remove it and download again.')
    print(f'Verified: {target}')
    if args.extract:
        manifest = json.loads((root / 'data' / 'manifest.json').read_text(encoding='utf-8'))
        expected = {x['path']: x for x in manifest['files'] if x['year'] == args.year}
        with zipfile.ZipFile(target) as archive:
            if set(archive.namelist()) != set(expected) | {'year_manifest.json'}:
                raise RuntimeError('Unexpected ZIP member list.')
            for name, item in expected.items():
                destination = args.output / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                sha = hashlib.sha256()
                size = 0
                with archive.open(name) as source, destination.open('wb') as out:
                    while chunk := source.read(4*1024*1024):
                        out.write(chunk)
                        sha.update(chunk)
                        size += len(chunk)
                if size != item['bytes'] or sha.hexdigest() != item['sha256']:
                    raise RuntimeError(f'CSV checksum/size mismatch: {name}')
        print(f'Extracted and verified {len(expected)} monthly CSV files.')


if __name__ == '__main__':
    main()
