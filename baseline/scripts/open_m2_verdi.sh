#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
contexts="${1:-4}"
wg_threads="${2:-64}"
wave_file="waves/tinygpu_m2_n${contexts}_wg${wg_threads}.fsdb"
if [[ ! -s "$wave_file" ]]; then
    echo "Run scripts/run_m2_vcs.sh with the Verdi PLI enabled to create M2 FSDB."
    exit 1
fi
verdi -sv "+define+M2_NUM_CONTEXTS=${contexts}" "+define+M2_WG_THREADS=${wg_threads}" \
    -f sim/filelist_m2_rtl.f -f sim/filelist_m2_tb.f \
    -top tb_wave_control_subsystem -ssf "$wave_file" &
