#!/usr/bin/env python3
"""Losslessly partition a CSV by checkout year/month and package by year.

Uses only Python's standard library. Original CSV record bytes, headers,
quoting, NA values and order within each month are preserved.
"""
import argparse
import concurrent.futures
import csv
import hashlib
import json
import os
from pathlib import Path
import time
import zipfile

EXPECTED = ['usageclass', 'checkouttype', 'materialtype', 'checkoutyear',
            'checkoutmonth', 'checkouts', 'title', 'subjects', 'creator',
            'publisher', 'publicationyear', 'isbn']
TAG = 'spl-monthly-2005-2025-v1'
BASE_URL = f'https://github.com/wyfARTHUR/DSCPproject7/releases/download/{TAG}'


def save_json(path, obj):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    os.replace(temp, path)


class TrackedLines:
    def __init__(self, stream):
        self.stream = stream
        self.pending = []
        self.sha = hashlib.sha256()
        self.bytes = 0

    def __iter__(self):
        return self

    def __next__(self):
        raw = next(self.stream)
        self.pending.append(raw)
        self.sha.update(raw)
        self.bytes += len(raw)
        return raw.decode('utf-8')

    def take_record(self):
        raw = b''.join(self.pending)
        self.pending.clear()
        return raw


def split(source, output, limit):
    source, output = Path(source), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    csv_root = output / 'monthly_csv'
    if csv_root.exists() and any(csv_root.rglob('*.csv')):
        raise RuntimeError('Output contains CSVs already; use a new output directory.')
    before = source.stat()
    writers, entries, per_month, digests = {}, {}, {}, {}
    total = 0
    started = last = time.monotonic()
    csv.field_size_limit(100_000_000)
    try:
        with source.open('rb', buffering=4*1024*1024) as stream:
            lines = TrackedLines(stream)
            reader = csv.reader(lines, strict=True)
            header = next(reader)
            raw_header = lines.take_record()
            if header != EXPECTED:
                raise ValueError(f'Unexpected header: {header}')
            for row in reader:
                raw = lines.take_record()
                if len(row) != len(header):
                    raise ValueError(f'Record {total+1}: expected {len(header)} columns, got {len(row)}')
                year, month = int(row[3]), int(row[4])
                if not 2005 <= year <= 2025 or not 1 <= month <= 12:
                    raise ValueError(f'Record {total+1}: invalid period {year}-{month}')
                key = (year, month)
                part = per_month.get(key, 0)
                full_key = (year, month, part)
                if full_key in entries and entries[full_key]['bytes'] + len(raw) >= limit:
                    writers[full_key].close()
                    part += 1
                    per_month[key] = part
                    full_key = (year, month, part)
                if full_key not in writers:
                    name = f'spl-checkouts_{year:04d}-{month:02d}_part{part+1:02d}.csv'
                    path = csv_root / str(year) / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    writers[full_key] = path.open('wb', buffering=256*1024)
                    writers[full_key].write(raw_header)
                    digests[full_key] = hashlib.sha256(raw_header)
                    entries[full_key] = dict(path=path.relative_to(output).as_posix(),
                                             year=year, month=month, part=part+1,
                                             rows=0, bytes=len(raw_header))
                if len(raw_header) + len(raw) >= limit:
                    raise ValueError('A single CSV record exceeds the requested file limit.')
                writers[full_key].write(raw)
                digests[full_key].update(raw)
                entry = entries[full_key]
                entry['rows'] += 1
                entry['bytes'] += len(raw)
                total += 1
                now = time.monotonic()
                if now - last >= 15:
                    print(f'SPLIT {lines.bytes/before.st_size:.1%} | {total:,} rows | {len(entries)} files', flush=True)
                    save_json(output / 'progress.json', dict(stage='splitting', bytes=lines.bytes,
                                                             source_bytes=before.st_size, rows=total,
                                                             files=len(entries)))
                    last = now
            if lines.pending:
                raise ValueError('Unconsumed bytes at end of CSV.')
    finally:
        for handle in writers.values():
            handle.close()
    after = source.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise RuntimeError('Source changed during processing.')
    files = []
    for key in sorted(entries):
        entry = entries[key]
        entry['sha256'] = digests[key].hexdigest()
        assert (output / entry['path']).stat().st_size == entry['bytes']
        assert entry['bytes'] < limit
        files.append(entry)
    assert sum(x['bytes'] - len(raw_header) for x in files) + len(raw_header) == before.st_size
    manifest = dict(format_version=1, source=dict(filename=source.name, bytes=before.st_size,
                    sha256=lines.sha.hexdigest(), rows=total, columns=header,
                    header_bytes=len(raw_header)), split=dict(method='checkoutyear + checkoutmonth',
                    csv_max_bytes_exclusive=limit, encoding='UTF-8',
                    record_bytes_preserved=True, order_within_month_preserved=True,
                    global_order_preserved=False), files=files)
    save_json(output / 'manifest.json', manifest)
    print(f'SPLIT COMPLETE | {total:,} rows | {len(files)} files | {time.monotonic()-started:.1f}s', flush=True)


def verify(output):
    output = Path(output)
    manifest = json.loads((output / 'manifest.json').read_text(encoding='utf-8'))
    csv.field_size_limit(100_000_000)
    total = 0
    for index, entry in enumerate(manifest['files'], 1):
        path = output / entry['path']
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            while chunk := stream.read(4*1024*1024):
                digest.update(chunk)
        assert digest.hexdigest() == entry['sha256'], path
        assert path.stat().st_size == entry['bytes'] < manifest['split']['csv_max_bytes_exclusive']
        count = 0
        with path.open('r', encoding='utf-8', newline='') as stream:
            reader = csv.reader(stream, strict=True)
            assert next(reader) == manifest['source']['columns'], path
            for row in reader:
                assert len(row) == len(manifest['source']['columns']), path
                assert int(row[3]) == entry['year'] and int(row[4]) == entry['month'], path
                count += 1
        assert count == entry['rows'], path
        total += count
        if index % 12 == 0 or index == len(manifest['files']):
            print(f'VERIFY {index}/{len(manifest["files"])} files | {total:,} rows', flush=True)
    assert total == manifest['source']['rows']
    save_json(output / 'verification.json', dict(verified=True, rows=total,
        files=len(manifest['files']), checks=['SHA-256 for every CSV', 'CSV parsing of every row',
        'column count', 'year/month membership', 'row counts', 'file sizes', 'source byte accounting']))
    print('CSV VERIFICATION COMPLETE', flush=True)


def package(output, workers):
    output = Path(output)
    manifest = json.loads((output / 'manifest.json').read_text(encoding='utf-8'))
    verification = json.loads((output / 'verification.json').read_text(encoding='utf-8'))
    assert verification['verified']
    archive_dir = output / 'archives'
    archive_dir.mkdir(exist_ok=True)
    years = sorted(set(x['year'] for x in manifest['files']))

    def one(year):
        files = [x for x in manifest['files'] if x['year'] == year]
        target = archive_dir / f'spl-checkouts_{year}.zip'
        temp = target.with_suffix('.zip.tmp')
        with zipfile.ZipFile(temp, 'w', compression=zipfile.ZIP_DEFLATED,
                             compresslevel=6, allowZip64=True) as z:
            for entry in files:
                z.write(output / entry['path'], arcname=entry['path'])
            z.writestr('year_manifest.json', json.dumps(dict(source=manifest['source'],
                       split=manifest['split'], files=files), indent=2) + '\n')
        with zipfile.ZipFile(temp) as z:
            for entry in files:
                sha = hashlib.sha256()
                with z.open(entry['path']) as stream:
                    while chunk := stream.read(4*1024*1024):
                        sha.update(chunk)
                assert sha.hexdigest() == entry['sha256'], entry['path']
        os.replace(temp, target)
        assert target.stat().st_size < 2*1024**3, 'Release asset must be smaller than 2 GiB.'
        sha = hashlib.sha256()
        with target.open('rb') as stream:
            while chunk := stream.read(4*1024*1024):
                sha.update(chunk)
        result = dict(year=year, filename=target.name, bytes=target.stat().st_size,
                      sha256=sha.hexdigest(), rows=sum(x['rows'] for x in files),
                      csv_files=len(files), uncompressed_csv_bytes=sum(x['bytes'] for x in files),
                      url=f'{BASE_URL}/{target.name}')
        print(f'PACKAGED {year} | {result["bytes"]:,} bytes | archive contents verified', flush=True)
        return result

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        archives = sorted(pool.map(one, years), key=lambda x: x['year'])
    save_json(output / 'archives.json', dict(release_tag=TAG, archives=archives))
    checksums = [f'{x["sha256"]}  {x["filename"]}' for x in archives]
    (output / 'SHA256SUMS.txt').write_text('\n'.join(checksums) + '\n', encoding='ascii')
    print(f'PACKAGING COMPLETE | {len(archives)} archives | {sum(x["bytes"] for x in archives):,} bytes', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=['split', 'verify', 'package', 'all'])
    parser.add_argument('--source', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--max-csv-bytes', type=int, default=3_900_000_000)
    parser.add_argument('--workers', type=int, default=3)
    args = parser.parse_args()
    if args.stage in ['split', 'all']:
        if not args.source:
            parser.error('--source is required for splitting')
        split(args.source, args.output, args.max_csv_bytes)
    if args.stage in ['verify', 'all']:
        verify(args.output)
    if args.stage in ['package', 'all']:
        package(args.output, args.workers)


if __name__ == '__main__':
    main()
