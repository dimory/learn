#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
contexts="${1:-4}"
wg_threads="${2:-64}"
scenario="${3:-0}"
if [[ ! "$contexts" =~ ^[1-9][0-9]*$ || ! "$wg_threads" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 [positive Context count] [positive Workgroup thread count] [scenario 0..9]" >&2
    exit 2
fi
if [[ ! "$scenario" =~ ^[0-9]+$ ]]; then
    echo "Scenario must be 0 (all) or 1..9." >&2
    exit 2
fi
if (( scenario > 9 )); then
    echo "Scenario must be 0 (all) or 1..9." >&2
    exit 2
fi
if ! command -v verdi >/dev/null 2>&1; then
    echo "Verdi is not in PATH. Source your Verdi2016 setup, then run make m2_env." >&2
    exit 127
fi
if [[ "$scenario" == 0 ]]; then
    wave_file="waves/tinygpu_m2_n${contexts}_wg${wg_threads}.fsdb"
else
    wave_file="waves/tinygpu_m2_n${contexts}_wg${wg_threads}_s${scenario}.fsdb"
fi
if [[ ! -s "$wave_file" ]]; then
    echo "Run scripts/run_m2_vcs.sh ${contexts} ${wg_threads} ${scenario} with the Verdi PLI enabled to create this M2 FSDB."
    exit 1
fi
verdi -sv "+define+M2_NUM_CONTEXTS=${contexts}" "+define+M2_WG_THREADS=${wg_threads}" \
    -f sim/filelist_m2_rtl.f -f sim/filelist_m2_tb.f \
    -top tb_wave_control_subsystem -ssf "$wave_file" &
