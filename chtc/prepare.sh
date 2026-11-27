#!/usr/bin/env bash
set -euo pipefail
# Small login-node bootstrap: standard shell/tar/sha256sum and Condor, no R/Python.
mode="${1:-prepare}"
run_arg="${2:-chtc_runs/run1}"
[[ $# -le 2 && ( "$mode" == prepare || "$mode" == merge || "$mode" == fit || "$mode" == all ) ]] || { echo 'Use prepare|merge|fit|all RUN_DIR' >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
if [[ -f config/chtc.env ]]; then source config/chtc.env; fi
image="${DSCP_CONTAINER_IMAGE:-}"
if [[ -z "$image" || "$image" == *REPLACE* || ! "$image" =~ ^[A-Za-z0-9_./:@+-]+$ ]]; then
  echo 'Set a real DSCP_CONTAINER_IMAGE in config/chtc.env first.' >&2; exit 2
fi
expected="$(tr -d '\r\n' < chtc/templates/analysis.sha256)"
actual="$(sha256sum config/analysis.json | cut -d' ' -f1)"
if [[ "$expected" != "$actual" ]]; then echo 'Analysis config changed. Regenerate templates with Rscript chtc/make_templates.R in an R environment.' >&2; exit 2; fi
mkdir -p "$run_arg"
run="$(cd "$run_arg" && pwd)"
if [[ "$run" == "$root" || "$root" == "$run/"* || "$run" == /staging/* ]]; then echo 'Use a dedicated submission directory under /home, not /staging or the repository root.' >&2; exit 2; fi
if [[ "$mode" == prepare || "$mode" == all ]]; then
  [[ ! -e "$run/code.tar.gz" ]] || { echo 'Run exists; use a new run directory or resume its DAG.' >&2; exit 2; }
  {
    find R scripts chtc -type f \( -name '*.R' -o -name '*.sh' -o -name '*.sub' -o -name '*.dag' -o -name '*.txt' -o -name '*.sha256' \)
    printf '%s\n' config/analysis.json config/format_map.tsv data/manifest.json data/archives.json
  } | LC_ALL=C sort -u > "$run/source_files.txt"
  while IFS= read -r file; do [[ ! -L "$file" ]] || { echo 'Source links are not supported.' >&2; exit 2; }; done < "$run/source_files.txt"
  while IFS= read -r file; do sha256sum "$file"; done < "$run/source_files.txt" > "$run/source_checksums.txt"
  printf '%s\n' "$image" > "$run/container_image.txt"
else
  [[ -f "$run/code.tar.gz" ]] || { echo 'Run prepare first.' >&2; exit 2; }
  [[ "$(cat "$run/container_image.txt")" == "$image" ]] || { echo 'Container changed; start a new run.' >&2; exit 2; }
  sha256sum --check --status "$run/source_checksums.txt" || { echo 'Code/config changed; start a new run.' >&2; exit 2; }
  if [[ "$mode" == fit ]]; then
    sha256sum --check --status "$run/override_checksum.txt" || { echo 'Overrides changed; run merge first.' >&2; exit 2; }
    [[ -s "$run/matching-bundle.rds" ]] || { echo 'Missing merge outputs.' >&2; exit 2; }
    while IFS= read -r shard; do [[ -s "$run/shard-$shard-input.rds" ]] || { echo "Missing shard $shard" >&2; exit 2; }; done < "$run/shards.txt"
  else
    while IFS= read -r year; do [[ -s "$run/year-$year.rds" ]] || { echo "Missing year $year" >&2; exit 2; }; done < "$run/years.txt"
  fi
fi
if [[ "$mode" != fit ]]; then
  cp "$run/source_files.txt" "$run/bundle_files.txt"
  printf '%s\n' config/match_overrides.tsv >> "$run/bundle_files.txt"
  tar -czf "$run/code.tar.gz" --transform='s,^,project/,' -T "$run/bundle_files.txt"
  sha256sum config/match_overrides.tsv > "$run/override_checksum.txt"
fi
mkdir -p "$run/logs"
cp chtc/job.sh "$run/job.sh"
chmod 755 "$run/job.sh"
cp chtc/templates/years.txt chtc/templates/shards.txt chtc/templates/*.dag "$run/"
for file in chtc/templates/*.sub; do
  sed -e "s|@CONTAINER_IMAGE@|$image|g" "$file" > "$run/$(basename "$file")"
done
printf 'Prepared %s (no jobs submitted).\nRun:\n  cd %q\n  condor_submit_dag %s.dag\n' "$mode" "$run" "$mode"
