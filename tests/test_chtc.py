"""Exercise generated CHTC transfer envelopes locally, without HTCondor/container.

Requires the R packages used by the project. Uses tiny synthetic ZIP inputs and
an isolated sandbox for each job; no real jobs are submitted.
"""
import csv
import hashlib
import io
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'chtc'))
from archive_io import unpack


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    (ROOT / 'tests/.tmp').mkdir(parents=True, exist_ok=True)
    fixture = Path(tempfile.mkdtemp(prefix='chtc-', dir=ROOT / 'tests/.tmp'))
    files = []
    for year in range(2019, 2022):
        for month in range(1, 13):
            period = f'{year}-{month:02d}'
            if period == '2020-05':
                continue
            t = (year-2019)*12+month-1
            path = fixture / f'monthly_csv/{year}/spl-checkouts_{period}_part01.csv'
            path.parent.mkdir(parents=True, exist_ok=True)
            rows = []
            for format, material, usage, half in [('print', 'BOOK', 'Physical', 6),
                                                ('ebook', 'EBOOK', 'Digital', 12),
                                                ('digital_audio', 'AUDIOBOOK', 'Digital', 18)]:
                total = 0
                for title, author in [('Alpha', 'Alice Writer'), ('Beta', 'Bob Author')]:
                    count = round(10000 * 2**(-t/half))
                    total += count
                    if format == 'print':
                        first, last = author.split()
                        author = f'{last}, {first}, 1970-'
                        title += ' / ' + author
                    elif format == 'digital_audio':
                        title += ' (Unabridged)'
                    rows.append([material, usage, year, month, count, title, author])
                rows.append([material, usage, year, month, 100000-total, 'Unmatchable background', 'NA'])
            with path.open('w', encoding='utf-8', newline='') as stream:
                writer = csv.writer(stream)
                writer.writerow(['materialtype', 'usageclass', 'checkoutyear', 'checkoutmonth', 'checkouts', 'title', 'creator'])
                writer.writerows(rows)
            files.append(dict(path=path.relative_to(fixture).as_posix(), year=year, month=month,
                              part=1, rows=len(rows), bytes=path.stat().st_size, sha256=sha(path)))
    manifest = fixture / 'manifest.json'
    manifest.write_text(json.dumps(dict(files=files)), encoding='utf-8')
    archives = []
    for year in range(2019, 2022):
        path = fixture / f'spl-checkouts_{year}.zip'
        with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for entry in files:
                if entry['year'] == year:
                    archive.write(fixture / entry['path'], entry['path'])
            archive.writestr('year_manifest.json', '{}')
        archives.append(dict(year=year, filename=path.name, bytes=path.stat().st_size, sha256=sha(path), url=path.as_uri()))
    catalog = fixture / 'archives.json'
    catalog.write_text(json.dumps(dict(archives=archives)), encoding='utf-8')
    config = json.loads((ROOT / 'config/analysis.json').read_text(encoding='utf-8'))
    overrides_path = fixture / 'overrides.tsv'
    overrides_path.write_text('title_norm\tcreator_norm\twork_id\tinclude\tnotes\n', encoding='utf-8')
    config.update(start_month='2019-01', end_month='2021-12', exclude_months=['2020-05'],
                  n_shards=3, input_manifest=str(manifest), match_overrides=str(overrides_path))
    config_path = fixture / 'analysis.json'
    config_path.write_text(json.dumps(config), encoding='utf-8')
    settings = json.loads((ROOT / 'config/chtc.example.json').read_text(encoding='utf-8'))
    settings['container_image'] = 'file:///staging/test/NOT_ACTUALLY_USED.sif'
    settings_path = fixture / 'chtc.json'
    settings_path.write_text(json.dumps(settings), encoding='utf-8')
    run = fixture / 'submit'

    def generate(mode, success=True, extra=()):
        result = subprocess.run([sys.executable, 'chtc/workflow.py', mode, '--run-dir', str(run),
            '--config', str(config_path), '--settings', str(settings_path), '--archive-catalog', str(catalog), *extra],
            cwd=ROOT, text=True, capture_output=True)
        if (result.returncode == 0) != success:
            raise AssertionError(result.stdout + result.stderr)
        return result

    generate('prepare')
    with tarfile.open(run / 'code.tar.gz') as archive:
        names = archive.getnames()
        assert not any('/.git/' in name or '/monthly_csv/' in name or name.endswith('.sif') for name in names)
    assert (run / 'code.tar.gz').stat().st_size < 1_000_000
    assert 'queue year from years.txt' in (run / 'year.sub').read_text()
    assert 'transfer_output_files = year-$(year).tar.gz' in (run / 'year.sub').read_text()
    assert 'PARENT YEARS CHILD MERGE' in (run / 'prepare.dag').read_text()
    assert 'PARENT FITS CHILD COMPARE' in (run / 'fit.dag').read_text()

    def job(stage, item, success=True):
        scratch = Path(tempfile.mkdtemp(prefix='sandbox-', dir=fixture))
        unpack(run / 'code.tar.gz', scratch)
        project = scratch / 'project'
        env = dict(os.environ, DSCP_JOB_SANDBOX=str(project), DSCP_TRANSFER_DIR=str(run),
                   DSCP_CPUS='1', DSCP_JOB_ID='LOCAL_TEST', RSCRIPT=os.environ.get('RSCRIPT', 'Rscript'))
        result = subprocess.run([sys.executable, str(project/'chtc/run_job.py'), stage, str(item), 'false'],
                                 env=env, text=True, capture_output=True)
        (fixture / f'{stage}-{item}.log').write_text(result.stdout + result.stderr, encoding='utf-8')
        if (result.returncode == 0) != success:
            raise AssertionError(result.stdout + result.stderr)
        if stage == 'year':
            assert not (project / 'data/monthly_csv').exists()
            assert not list((project / 'data').glob('spl-checkouts_*.zip'))
        print(f'LOCAL CHTC ENVELOPE PASSED: {stage} {item}', flush=True)

    for year in range(2019, 2022):
        job('year', year)
    job('merge', 0)
    blocked = generate('fit', success=False)
    assert 'Complete match_review.tsv' in blocked.stderr
    # A failed worker must still produce the declared diagnostic output archive.
    job('fit', 1, success=False)
    with tarfile.open(run / 'fit-shard-0001.tar.gz') as archive:
        status = json.load(archive.extractfile('run/job_status/fit-1.json'))
        assert status['success'] is False
    with (run / 'match_review.tsv').open(encoding='utf-8', newline='') as stream:
        reader = csv.DictReader(stream, delimiter='\t')
        fields, review = reader.fieldnames, list(reader)
    for row in review:
        row.update(decision='accept', reviewer='SYNTHETIC_LOCAL_TEST')
    with (run / 'match_review.tsv').open('w', encoding='utf-8', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, delimiter='\t')
        writer.writeheader(); writer.writerows(review)
    generate('fit')
    for shard in range(1, 4):
        job('fit', shard)
    job('compare', 0)
    with tarfile.open(run / 'results.tar.gz') as archive:
        summary = json.load(archive.extractfile('run/results/run_summary.json'))
        assert summary['analysis_status'] == 'audit_sample_complete'
        rows = list(csv.DictReader(io.StringIO(archive.extractfile('run/results/format_comparison.tsv').read().decode()), delimiter='\t'))
        assert len(rows) == 4 and any(row['status'] == 'estimated' for row in rows)
        assert any(name.endswith('example_decay_curves.png') for name in archive.getnames())
    # Rebuild matching after an override and retain unchanged, real review entries.
    overrides_path.write_text('title_norm\tcreator_norm\twork_id\tinclude\tnotes\nbeta\tbob author\t\tFALSE\tSynthetic exclusion\n', encoding='utf-8')
    generate('merge')
    assert 'match_review.tsv' in (run / 'merge.sub').read_text().split('transfer_input_files = ')[1].splitlines()[0]
    job('merge', 0)
    with (run / 'match_review.tsv').open(encoding='utf-8', newline='') as stream:
        revised = list(csv.DictReader(stream, delimiter='\t'))
    assert len(revised) == 1 and revised[0]['decision'] == 'accept' and revised[0]['reviewer'] == 'SYNTHETIC_LOCAL_TEST'
    # The full unattended DAG is available only for explicitly preliminary runs.
    exploratory = fixture / 'exploratory'
    command = [sys.executable, 'chtc/workflow.py', 'all', '--run-dir', str(exploratory),
               '--config', str(config_path), '--settings', str(settings_path), '--archive-catalog', str(catalog)]
    denied = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    assert denied.returncode != 0 and 'preliminary' in denied.stderr
    subprocess.run(command + ['--allow-unreviewed'], cwd=ROOT, capture_output=True, check=True)
    assert 'PARENT MERGE CHILD FITS' in (exploratory / 'all.dag').read_text()
    assert 'fit $(shard) true' in (exploratory / 'fit.sub').read_text()
    # Reject archive traversal and direct execution inside the real checkout.
    bad = fixture / 'bad.tar.gz'
    with tarfile.open(bad, 'w:gz') as archive:
        member = tarfile.TarInfo('../escaped.txt'); member.size = 1
        archive.addfile(member, io.BytesIO(b'x'))
    try:
        unpack(bad, fixture / 'safe')
    except ValueError:
        pass
    else:
        raise AssertionError('Unsafe archive accepted')
    guard = subprocess.run([sys.executable, 'chtc/run_job.py', 'year', '2019', 'false'], cwd=ROOT,
        env=dict(os.environ, DSCP_JOB_SANDBOX=str(ROOT), DSCP_TRANSFER_DIR=str(run)), capture_output=True, text=True)
    assert guard.returncode != 0 and 'never in your Git checkout' in guard.stderr
    print('CHTC TRANSFER WORKFLOW TESTS PASSED:', fixture, flush=True)


if __name__ == '__main__':
    main()
