# DSCPproject7

SPL checkout data preparation for the DSCP group project. The supplied source CSV
is partitioned by `checkoutyear` and `checkoutmonth`. The monthly CSV files are
tracked directly in Git under `data/monthly_csv/YYYY/`, so a normal `git clone`
or `git pull` retrieves the data without extracting ZIPs or installing Git LFS.
Yearly ZIPs are also available in [GitHub Releases](https://github.com/wyfARTHUR/DSCPproject7/releases/tag/spl-monthly-2005-2025-v1).

## R analysis and CHTC/HTCondor workflow

The analysis pipeline now covers yearly CSV-to-Parquet preparation, cross-year
work matching and manual match audit, parallel exponential share-decay fitting,
book fixed-effect comparisons, pandemic sensitivity, and plots.
See **[CHTC.md](CHTC.md)** for the Chinese CHTC setup guide using the course's
Apptainer and DAGMan patterns. Statistical choices, output definitions and tests
are documented in **[ANALYSIS.md](ANALYSIS.md)**.

```sh
cp config/chtc.example.json config/chtc.json
# First build/check the R container and fill its real URI; follow CHTC.md.
python3 chtc/workflow.py prepare --run-dir chtc_runs/run1
cd chtc_runs/run1
condor_submit_dag prepare.dag
# When preparation finishes, complete match_review.tsv; then generate fit.dag.
```

The real container path and resource requests must match your environment. This repository does
not automatically submit jobs or treat unreviewed matches as final results.

## Dataset and project size requirement

- Source filename: `spl-monthly-checkouts_2005-2025.csv`.
- Source size: **11,362,453,085 bytes** (11.36 GB, 10.58 GiB).
- Data rows, excluding the header: **45,821,586**. Columns: **12**.
- Partitions: **228 monthly CSVs** tracked directly in Git, also available as **20 yearly ZIPs**.
- Monthly CSV sizes: **17.64 to 65.76 MB**.
- Total ZIP download size: **3,338,096,958 bytes** (3.34 GB).

The supplied project PDF asks for about 10-100 GB of data, with smaller files
below about 4 GB suitable for parallel jobs. The original uncompressed dataset
meets the total-size range, and every monthly CSV is below 4 GB. Compression
reduces download size without reducing the dataset. The splitter enforces a
strict CSV limit of 3,900,000,000 bytes and can add part numbers if needed.

**Actual coverage differs from the filename:** records cover January 2006 through
February 2025. There are no 2005 records. May and June 2024 are absent from the
source. March-December 2025 are also absent. These gaps are retained; no empty
months or synthetic records were added. All other months from January 2006
through February 2025 are present.

The source was supplied as a local file; the group proposal identifies Zenodo
as its source. The exact original download URL and license were not supplied or
independently verified. Add the original dataset citation
and applicable terms before submitting the project report.

## Download data

On a remote Linux machine, clone the repository to get all monthly CSVs:

```sh
git clone https://github.com/wyfARTHUR/DSCPproject7.git
cd DSCPproject7
find data/monthly_csv -type f -name '*.csv' | wc -l
```

The count should be **228** after the full dataset is available. The CSV working
files occupy about **11.36 GB**, plus the space required by Git's compressed
object database. No ZIP extraction, Python dependency, or Git LFS step is needed
for this method. Keep enough disk space for both the CSV files and `.git`.

If you cloned this repository earlier, get the CSVs with:

```sh
cd DSCPproject7
git pull --ff-only origin main
```

For example, January 2023 is stored at:

```text
data/monthly_csv/2023/spl-checkouts_2023-01_part01.csv
```

Optionally verify every monthly CSV against the manifest with Python 3.9+:

```sh
python3 scripts/verify_git_data.py
```

CSV line endings and content bytes are preserved by `.gitattributes` on Windows
and Linux. All files are ordinary Git blobs, not LFS pointers.

### Alternative: download yearly ZIPs

To download and extract one yearly archive using Python 3.9+ (standard library only):

```sh
python scripts/download_data.py --year 2023 --output data_download --extract
```

The downloader validates the ZIP size and SHA-256, then validates every extracted
CSV. Each ZIP contains `monthly_csv/YYYY/*.csv` and `year_manifest.json`.
Use the ZIP links below for manual downloads. `SHA256SUMS.txt` covers all ZIPs.
Use the named `spl-checkouts_YYYY.zip` assets when downloading yearly archives.

For R, a monthly file can be read with:

```r
d <- read.csv("data/monthly_csv/2023/spl-checkouts_2023-01_part01.csv", na.strings = "NA")
```

The partition format supports independent jobs by month or year. On CHTC, arrange
for each job to download the yearly archive it needs on its execution machine,
process the relevant monthly CSVs, and remove downloaded/extracted input files
before exit, as directed by the supplied project specification.

## Yearly archives

| Year | Monthly CSVs | Data rows | CSV size (MB) | ZIP size (MB) | Download |
| --- | ---: | ---: | ---: | ---: | --- |
| 2006 | 12 | 1,938,925 | 390.42 | 108.91 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2006.zip) |
| 2007 | 12 | 2,040,106 | 421.44 | 118.33 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2007.zip) |
| 2008 | 12 | 2,136,504 | 457.53 | 130.00 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2008.zip) |
| 2009 | 12 | 2,226,650 | 497.85 | 143.48 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2009.zip) |
| 2010 | 12 | 2,190,185 | 513.58 | 149.80 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2010.zip) |
| 2011 | 12 | 2,335,873 | 553.16 | 162.77 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2011.zip) |
| 2012 | 12 | 2,397,811 | 579.64 | 171.39 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2012.zip) |
| 2013 | 12 | 2,513,758 | 624.05 | 186.03 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2013.zip) |
| 2014 | 12 | 2,609,700 | 658.72 | 196.40 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2014.zip) |
| 2015 | 12 | 2,729,531 | 689.07 | 205.38 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2015.zip) |
| 2016 | 12 | 2,787,319 | 707.36 | 210.70 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2016.zip) |
| 2017 | 12 | 2,820,433 | 718.56 | 213.58 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2017.zip) |
| 2018 | 12 | 2,665,098 | 694.82 | 205.79 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2018.zip) |
| 2019 | 12 | 2,589,001 | 692.12 | 203.55 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2019.zip) |
| 2020 | 12 | 1,721,376 | 408.00 | 110.69 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2020.zip) |
| 2021 | 12 | 2,242,272 | 577.15 | 164.50 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2021.zip) |
| 2022 | 12 | 2,531,508 | 697.39 | 208.67 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2022.zip) |
| 2023 | 12 | 2,676,026 | 745.91 | 226.58 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2023.zip) |
| 2024 | 10 | 2,202,269 | 607.02 | 182.48 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2024.zip) |
| 2025 | 2 | 467,241 | 128.70 | 39.06 | [ZIP](https://github.com/wyfARTHUR/DSCPproject7/releases/download/spl-monthly-2005-2025-v1/spl-checkouts_2025.zip) |

MB and GB above use decimal units. GiB uses 1,073,741,824 bytes.

## Reproduce preparation

Python 3.9+ is sufficient; no third-party packages are required. Use a new output
directory with adequate disk space for the uncompressed partitions and archives.

```sh
python scripts/prepare_data.py all --source /path/to/spl-monthly-checkouts_2005-2025.csv --output prepared_data
```

Stages can also be invoked separately with `split`, `verify`, and `package`.
The default package step uses three compression threads. This is data preparation;
the project's statistical parallel computation is a separate subsequent task.

The parser handles quoted fields, escaped quotes, embedded newlines, and UTF-8.
It validates all 12 columns and every year/month, while retaining each original
record's bytes. Every output has the original 152-byte header. Quoting, `NA`
values, text, duplicates, and column order are preserved. Records retain their
source order within each month. Grouping by month changes global record order.
No records are cleaned, aggregated, filtered, or deduplicated.

## Validation and metadata

- `data/manifest.json`: source hash, row count, schema, and every CSV's period,
  row count, byte size and SHA-256.
- `data/archives.json`: each yearly ZIP's URL, size, row count and SHA-256.
- `data/SHA256SUMS.txt`: portable ZIP checksums.
- `data/verification.json`: full CSV verification result.

All 45,821,586 source records were parsed during splitting. Every monthly CSV
was then independently reread to check its header, 12-column structure, period,
row count, byte size and SHA-256. The partition bytes reconcile to the source size
after accounting for repeated headers. Every ZIP was fully decompressed and its
CSV member hashes checked before upload. Uploaded asset sizes and SHA-256 hashes
are checked against GitHub's server-reported values before publishing.

Source SHA-256:

```text
8ca3036ed886660b01e6b3c93bf376c2131e2c385d29347ea73199749195872e
```

Monthly CSV files are tracked directly in Git. ZIPs remain available as release
assets. GitHub documents its release asset limits
[here](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).
