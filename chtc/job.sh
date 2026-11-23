#!/usr/bin/env bash
set -euo pipefail
# This script runs inside the requested R container on the execute node.
transfer_dir="$PWD"
work_dir="$(mktemp -d "$PWD/dscp-job.XXXXXX")"
tar -xzf code.tar.gz -C "$work_dir"
export DSCP_JOB_SANDBOX="$work_dir/project"
export DSCP_TRANSFER_DIR="$transfer_dir"
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OMP_NUM_THREADS="${DSCP_CPUS:-1}"
python3 "$DSCP_JOB_SANDBOX/chtc/run_job.py" "$@"
