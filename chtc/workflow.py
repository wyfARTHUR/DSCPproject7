#!/usr/bin/env python3
"""Generate small HTCondor submit files and DAGs; never submits jobs itself.

Uses Python 3.9+ and its standard library, so no R is needed on learn.
"""
import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def snapshot(config_path, catalog_path):
    cfg = json.loads(Path(config_path).read_text(encoding='utf-8'))
    payload = {}
    for folder in ['R', 'scripts', 'chtc']:
        for path in sorted((ROOT / folder).iterdir()):
            if path.is_file() and path.suffix in ['.R', '.py', '.sh', '.def', '.sub']:
                payload[path.relative_to(ROOT).as_posix()] = path.read_bytes()
    metadata = {
        'data/manifest.json': ROOT / cfg['input_manifest'],
        'data/archives.json': Path(catalog_path),
        'config/format_map.tsv': ROOT / cfg['format_map'],
        'config/match_overrides.tsv': ROOT / cfg['match_overrides'],
    }
    for name, path in metadata.items():
        payload[name] = path.read_bytes()
    cfg.update(input_dir='data/monthly_csv', input_manifest='data/manifest.json',
               format_map='config/format_map.tsv', match_overrides='config/match_overrides.tsv')
    payload['config/analysis.json'] = (json.dumps(cfg, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    first, last = int(cfg['start_month'][:4]), int(cfg['end_month'][:4])
    if first > last or not isinstance(cfg['n_shards'], int) or cfg['n_shards'] < 1:
        raise ValueError('Invalid year/shard configuration.')
    if cfg['min_post_peak_months'] < 12:
        raise ValueError('At least 12 post-peak observed months are required.')
    manifest = json.loads(payload['data/manifest.json'])
    catalog = json.loads(payload['data/archives.json'])
    years = list(range(first, last + 1))
    available = {item['year'] for item in catalog['archives']}
    if not set(years).issubset(available):
        raise ValueError('Archive catalog does not cover every configured year.')
    for entry in manifest['files']:
        if not entry['path'].startswith('monthly_csv/') or '..' in Path(entry['path']).parts:
            raise ValueError('Unsafe CSV manifest path.')
    return cfg, years, payload


def save_bundle(path, payload):
    temp = path.with_suffix('.partial')
    with tarfile.open(temp, 'w:gz', compresslevel=6) as archive:
        for name, content in sorted(payload.items()):
            info = tarfile.TarInfo('project/' + name)
            info.size = len(content)
            info.mode = 0o644
            info.mtime = 0
            archive.addfile(info, io.BytesIO(content))
    temp.replace(path)


def settings_checked(path):
    settings = json.loads(Path(path).read_text(encoding='utf-8'))
    image = settings['container_image']
    if 'REPLACE' in image or not re.match(r'^(file:///|osdf:///|docker://|/)', image) or re.search(r'[\s"#;]', image):
        raise ValueError('Set container_image to your built .sif path or container URI in config/chtc.json.')
    for stage in ['year', 'merge', 'fit', 'compare']:
        if not isinstance(settings[stage + '_cpus'], int) or settings[stage + '_cpus'] < 1:
            raise ValueError('Invalid CPU request for ' + stage)
        for resource in ['memory', 'disk']:
            if not re.fullmatch(r'[1-9][0-9]*(KB|MB|GB|TB)', settings[stage + '_' + resource]):
                raise ValueError('Use quantities like 8GB for resource requests.')
    return settings


def validate_review(run, allow):
    with tarfile.open(run / 'review-bundle.tar.gz', 'r:gz') as archive:
        base = archive.extractfile('run/audit/match_review.tsv').read().decode('utf-8-sig')
    expected = {row['work_id']: row['review_signature'] for row in csv.DictReader(io.StringIO(base), delimiter='\t')}
    with (run / 'match_review.tsv').open(encoding='utf-8-sig', newline='') as stream:
        reader = csv.DictReader(stream, delimiter='\t')
        if not {'work_id', 'review_signature', 'decision', 'reviewer'}.issubset(reader.fieldnames or []):
            raise ValueError('Incomplete manual review table schema.')
        rows = list(reader)
    if len(rows) != len(expected) or len({row['work_id'] for row in rows}) != len(rows):
        raise ValueError('Do not delete or duplicate audit rows.')
    for row in rows:
        if expected.get(row['work_id']) != row['review_signature']:
            raise ValueError('Audit IDs/signatures differ from the merge output.')
        decision = row['decision']
        if decision not in ['', 'accept', 'reject']:
            raise ValueError('Audit decision must be accept, reject, or blank.')
        if not allow and (decision not in ['accept', 'reject'] or not row['reviewer'].strip()):
            raise ValueError('Complete match_review.tsv first; use --allow-unreviewed only for preliminary runs.')
    if not rows:
        raise ValueError('No auditable matching works. Inspect matching and overrides.')


def submit_text(stage, settings, inputs, outputs, arguments, queue):
    cpu = settings[stage + '_cpus']
    lines = ['universe = container', 'container_image = ' + settings['container_image'],
             'executable = job.sh', 'arguments = ' + arguments,
             'should_transfer_files = YES', 'when_to_transfer_output = ON_EXIT',
             'transfer_input_files = ' + ', '.join(['code.tar.gz'] + inputs),
             'transfer_output_files = ' + ', '.join(outputs),
             f'request_cpus = {cpu}', 'request_memory = ' + settings[stage + '_memory'],
             'request_disk = ' + settings[stage + '_disk'],
             f'environment = "DSCP_CPUS={cpu} DSCP_JOB_ID=$(Cluster).$(Process)"',
             f'log = logs/{stage}_$(Cluster).log',
             f'output = logs/{stage}_$(Cluster)_$(Process).out',
             f'error = logs/{stage}_$(Cluster)_$(Process).err']
    if settings.get('require_staging', True):
        lines.append('requirements = (HasCHTCStaging == true)')
    return '\n'.join(lines + [queue, ''])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'merge', 'fit', 'all'])
    parser.add_argument('--run-dir', type=Path, required=True)
    parser.add_argument('--settings', type=Path)
    parser.add_argument('--config', type=Path)
    parser.add_argument('--archive-catalog', type=Path)
    parser.add_argument('--allow-unreviewed', action='store_true')
    args = parser.parse_args()
    if args.mode == 'all' and not args.allow_unreviewed:
        parser.error('all is preliminary only: specify --allow-unreviewed or use prepare, review, fit.')
    run = args.run_dir.resolve()
    if run == ROOT or ROOT.is_relative_to(run):
        parser.error('Use a dedicated run directory, not the repository root or its ancestor.')
    run.mkdir(parents=True, exist_ok=True)
    metadata_path = run / 'run_metadata.json'
    previous = json.loads(metadata_path.read_text(encoding='utf-8')) if metadata_path.exists() else None
    if args.mode in ['prepare', 'all'] and previous:
        parser.error('Run already exists. Use a new run directory, or resume the existing DAG / use merge or fit.')
    if args.mode in ['merge', 'fit'] and not previous:
        parser.error('Run prepare first.')
    config_path = (args.config or Path(previous['config_source'] if previous else ROOT / 'config/analysis.json')).resolve()
    catalog_path = (args.archive_catalog or Path(previous['catalog_source'] if previous else ROOT / 'data/archives.json')).resolve()
    settings_path = (args.settings or Path(previous['settings_source'] if previous else ROOT / 'config/chtc.json')).resolve()
    settings = settings_checked(settings_path)
    cfg, years, payload = snapshot(config_path, catalog_path)
    hashes = {name: digest(content) for name, content in payload.items()}
    if previous:
        if previous['container_image'] != settings['container_image']:
            raise ValueError('Container changed. Start a new run.')
        changed = {name for name in set(hashes) | set(previous['source_hashes']) if hashes.get(name) != previous['source_hashes'].get(name)}
        allowed = {'config/match_overrides.tsv'} if args.mode == 'merge' else set()
        if changed - allowed:
            raise ValueError('Code/config/data metadata changed; use a new run directory. Changed: ' + ', '.join(sorted(changed)))
    if args.mode == 'merge':
        for year in years:
            if not (run / f'year-{year}.tar.gz').exists():
                raise ValueError(f'Missing yearly result archive: {year}')
    if args.mode == 'fit':
        validate_review(run, args.allow_unreviewed)
        for shard in range(1, cfg['n_shards'] + 1):
            if not (run / f'shard-{shard:04d}-input.tar.gz').exists():
                raise ValueError(f'Missing fit shard input: {shard}')
    if args.mode != 'fit':
        save_bundle(run / 'code.tar.gz', payload)
    shutil.copyfile(ROOT / 'chtc/job.sh', run / 'job.sh')
    (run / 'job.sh').chmod(0o755)
    (run / 'logs').mkdir(exist_ok=True)
    (run / 'years.txt').write_text(''.join(f'{year}\n' for year in years), encoding='ascii')
    (run / 'shards.txt').write_text(''.join(f'{s:04d}\n' for s in range(1, cfg['n_shards']+1)), encoding='ascii')
    allow = 'true' if args.allow_unreviewed else 'false'
    year_outputs = ['year-$(year).tar.gz']
    (run / 'year.sub').write_text(submit_text('year', settings, [], year_outputs,
                                            f'year $(year) {allow}', 'queue year from years.txt'), encoding='utf-8')
    (run / 'pilot.sub').write_text(submit_text('year', settings, [], year_outputs,
                                             f'year $(year) {allow}', f'queue year in ({years[0]})'), encoding='utf-8')
    shard_inputs = [f'shard-{s:04d}-input.tar.gz' for s in range(1, cfg['n_shards']+1)]
    merge_inputs = [f'year-{y}.tar.gz' for y in years]
    if args.mode == 'merge' and (run / 'match_review.tsv').exists():
        merge_inputs.append('match_review.tsv')
    (run / 'merge.sub').write_text(submit_text('merge', settings, merge_inputs,
        ['review-bundle.tar.gz', 'match_review.tsv', 'match_candidates.tsv'] + shard_inputs,
        f'merge 0 {allow}', 'queue'), encoding='utf-8')
    (run / 'fit.sub').write_text(submit_text('fit', settings, ['shard-$(shard)-input.tar.gz', 'match_review.tsv'],
        ['fit-shard-$(shard).tar.gz'], f'fit $(shard) {allow}', 'queue shard from shards.txt'), encoding='utf-8')
    fits = [f'fit-shard-{s:04d}.tar.gz' for s in range(1, cfg['n_shards']+1)]
    (run / 'compare.sub').write_text(submit_text('compare', settings,
        ['review-bundle.tar.gz', 'match_review.tsv'] + shard_inputs + fits,
        ['results.tar.gz'], f'compare 0 {allow}', 'queue'), encoding='utf-8')
    dags = {'prepare.dag': 'JOB YEARS year.sub\nJOB MERGE merge.sub\nPARENT YEARS CHILD MERGE\n',
            'merge.dag': 'JOB MERGE merge.sub\n',
            'fit.dag': 'JOB FITS fit.sub\nJOB COMPARE compare.sub\nPARENT FITS CHILD COMPARE\n'}
    if args.allow_unreviewed:
        dags['all.dag'] = dags['prepare.dag'] + dags['fit.dag'] + 'PARENT MERGE CHILD FITS\n'
    for name, content in dags.items():
        (run / name).write_text(content, encoding='ascii')
    metadata = dict(config_source=str(config_path), catalog_source=str(catalog_path),
        settings_source=str(settings_path), container_image=settings['container_image'],
        source_hashes=hashes, code_bundle_sha256=digest((run/'code.tar.gz').read_bytes()),
        years=years, n_shards=cfg['n_shards'], preliminary=args.allow_unreviewed)
    metadata_path.write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    print(f'Generated {run / (args.mode + ".dag")}')
    print('No jobs submitted. On learn, run:')
    print(f'  cd {run}')
    print(f'  condor_submit_dag {args.mode}.dag')


if __name__ == '__main__':
    main()
