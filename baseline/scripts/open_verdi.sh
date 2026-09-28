#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

if [[ ! -f waves/tinygpu_baseline.fsdb ]]; then
    echo "waves/tinygpu_baseline.fsdb does not exist. Run scripts/run_vcs.sh first."
    exit 1
fi

verdi \
    -sv \
    -f sim/filelist_rtl.f \
    -f sim/filelist_tb.f \
    -top tb_gpu \
    -ssf waves/tinygpu_baseline.fsdb &
