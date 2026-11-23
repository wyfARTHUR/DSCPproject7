#!/usr/bin/env python3
"""Execute one isolated HTCondor task and return only declared output archives."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback

from archive_io import pack, unpack


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('stage', choices=['year', 'merge', 'fit', 'compare'])
    parser.add_argument('item')
    parser.add_argument('allow_unreviewed', choices=['true', 'false'])
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    sandbox = Path(os.environ.get('DSCP_JOB_SANDBOX', '/invalid-sandbox')).resolve()
    if project != sandbox or (project / '.git').exists():
        raise RuntimeError('Run this only in the disposable sandbox created by chtc/job.sh, never in your Git checkout.')
    transfer = Path(os.environ['DSCP_TRANSFER_DIR']).resolve()
    if transfer == project or transfer.is_relative_to(project):
        raise RuntimeError('Transfer directory must be outside the project sandbox.')
    os.chdir(project)
    os.environ['DSCP_TASK_ID'] = args.item
    config = json.loads(Path('config/analysis.json').read_text(encoding='utf-8'))
    years = range(int(config['start_month'][:4]), int(config['end_month'][:4]) + 1)
    stage_id = args.stage + (('-' + args.item) if args.item != '0' else '')
    run = project / 'run'
    status_path = Path('run/job_status') / (stage_id + '.json')
    status_path.parent.mkdir(parents=True, exist_ok=True)
    began = time.monotonic()
    success, error = False, ''
    archives = []

    def R(script, extra=()):
        subprocess.run([os.environ.get('RSCRIPT', 'Rscript'), '--vanilla', script,
                        '--config', 'config/analysis.json', '--out', 'run', *map(str, extra)], check=True)

    try:
        if args.stage == 'year':
            year = int(args.item)
            if year not in years:
                raise ValueError('Year outside configured range.')
            subprocess.run([sys.executable, 'scripts/download_data.py', '--year', str(year), '--output', 'data', '--extract'], check=True)
            R('scripts/01_prepare_year.R', ['--year', year])
            archives = [(f'year-{year}.tar.gz', [f'run/{folder}/{year}{suffix}' for folder, suffix in
                [('annual', '.parquet'), ('annual', '-success.rds'), ('catalog', '.parquet'), ('totals', '.parquet')]] +
                [f'run/quality/{year}-input.tsv', f'run/quality/{year}-categories.tsv',
                 f'run/metrics/year-{year}.json', f'run/metrics/year-{year}-session.txt'])]
        elif args.stage == 'merge':
            for year in years:
                unpack(transfer / f'year-{year}.tar.gz', project)
            if (transfer / 'match_review.tsv').exists():
                (run / 'audit').mkdir(parents=True, exist_ok=True)
                shutil.copyfile(transfer / 'match_review.tsv', run / 'audit/match_review.tsv')
            R('scripts/02_build_shards.R')
            archives = [('review-bundle.tar.gz', ['run/audit', 'run/format_month_totals.parquet',
                                                  'run/merge_success.rds', 'run/metrics', 'run/job_status'])]
            for shard in range(1, config['n_shards'] + 1):
                archives.append((f'shard-{shard:04d}-input.tar.gz',
                    [f'run/shards/{shard:04d}', 'run/merge_success.rds', 'run/audit/review_expected.parquet']))
        elif args.stage == 'fit':
            shard = int(args.item)
            if not 1 <= shard <= config['n_shards']:
                raise ValueError('Invalid shard.')
            unpack(transfer / f'shard-{shard:04d}-input.tar.gz', project)
            (run / 'audit').mkdir(parents=True, exist_ok=True)
            shutil.copyfile(transfer / 'match_review.tsv', run / 'audit/match_review.tsv')
            R('scripts/03_fit_shard.R', ['--shard', shard, '--allow-unreviewed', args.allow_unreviewed])
            archives = [(f'fit-shard-{shard:04d}.tar.gz',
                         [f'run/fits/shard-{shard:04d}.parquet', f'run/fits/shard-{shard:04d}-success.rds',
                          f'run/metrics/fit-{shard:04d}.json', f'run/metrics/fit-{shard:04d}-session.txt'])]
        else:
            unpack(transfer / 'review-bundle.tar.gz', project)
            for shard in range(1, config['n_shards'] + 1):
                unpack(transfer / f'shard-{shard:04d}-input.tar.gz', project)
                unpack(transfer / f'fit-shard-{shard:04d}.tar.gz', project)
            shutil.copyfile(transfer / 'match_review.tsv', run / 'audit/match_review.tsv')
            R('scripts/04_compare_plot.R', ['--allow-unreviewed', args.allow_unreviewed])
            archives = [('results.tar.gz', ['run/results', 'run/metrics', 'run/job_status',
                                           'config/analysis.json', 'config/format_map.tsv', 'config/match_overrides.tsv'])]
        success = True
    except Exception as exception:
        error = repr(exception)
        traceback.print_exc()
    finally:
        status_path.write_text(json.dumps(dict(stage=stage_id, success=success, error=error,
            elapsed_seconds=time.monotonic()-began, job_id=os.environ.get('DSCP_JOB_ID', '')),
            indent=2) + '\n', encoding='utf-8')
        if not archives:
            if args.stage == 'year': names = [f'year-{int(args.item)}.tar.gz']
            elif args.stage == 'fit': names = [f'fit-shard-{int(args.item):04d}.tar.gz']
            elif args.stage == 'compare': names = ['results.tar.gz']
            else: names = ['review-bundle.tar.gz'] + [f'shard-{s:04d}-input.tar.gz' for s in range(1, config['n_shards']+1)]
            archives = [(name, []) for name in names]
        for name, paths in archives:
            pack(transfer / name, project, paths + [status_path.as_posix()])
        if args.stage == 'merge':
            for name in ['match_review.tsv', 'match_candidates.tsv']:
                source = run / 'audit' / name
                if source.exists():
                    shutil.copyfile(source, transfer / name)
                else:
                    (transfer / name).write_text('# Merge failed; inspect the job error log.\n', encoding='utf-8')
        # Remove downloaded raw inputs from this checked, disposable sandbox.
        if args.stage == 'year':
            raw = (project / 'data/monthly_csv').resolve()
            if raw.is_relative_to(project) and raw.exists():
                shutil.rmtree(raw)
            for zipfile in (project / 'data').glob('spl-checkouts_*.zip*'):
                zipfile.unlink()
    return 0 if success else 1


if __name__ == '__main__':
    raise SystemExit(main())
