#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
contexts="${1:-4}"
wg_threads="${2:-64}"
if [[ ! "$contexts" =~ ^[1-9][0-9]*$ || ! "$wg_threads" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 [positive Context count] [positive Workgroup thread count]" >&2
    exit 2
fi
run_tag="n${contexts}_wg${wg_threads}"
mkdir -p build logs waves
# VCS2016/Verdi2016 are the final acceptance tools. This script uses their
# existing PATH entries; it neither downloads nor substitutes a simulator.
vcs_args=(
    -full64 -sverilog -timescale=1ns/1ns -debug_access+all -kdb
    "+define+M2_NUM_CONTEXTS=${contexts}" "+define+M2_WG_THREADS=${wg_threads}"
    -top tb_wave_control_subsystem
    -f sim/filelist_m2_rtl.f -f sim/filelist_m2_tb.f
    "-Mdir=build/csrc_m2_${run_tag}"
    -o build/simv_m2 -l "logs/m2_vcs_${run_tag}_compile.log"
)
novas_root="${NOVAS_HOME:-${VERDI_HOME:-}}"
fsdb_enabled=0
if [[ -n "$novas_root" ]]; then
    pli_dir="$novas_root/share/PLI/VCS/LINUX64"
    if [[ -f "$pli_dir/novas.tab" && -f "$pli_dir/pli.a" ]]; then
        vcs_args+=(+define+FSDB -P "$pli_dir/novas.tab" "$pli_dir/pli.a")
        fsdb_enabled=1
    fi
fi
if [[ "$fsdb_enabled" == 0 ]]; then
    echo "FSDB disabled: set NOVAS_HOME or VERDI_HOME to your Verdi2016 installation."
fi
vcs "${vcs_args[@]}"
if [[ "$fsdb_enabled" == 1 ]]; then
    rm -f waves/tinygpu_m2.fsdb
fi
./build/simv_m2 -l "logs/m2_vcs_${run_tag}.log"
if ! grep -Eq "TinyGPU M2: ALL [0-9]+ SCENARIO GROUPS PASSED N=${contexts} WG=${wg_threads} " "logs/m2_vcs_${run_tag}.log"; then
    echo "M2 failed: missing complete regression PASS signature." >&2
    exit 1
fi
if [[ "$fsdb_enabled" == 1 ]]; then
    if [[ ! -s waves/tinygpu_m2.fsdb ]]; then
        echo "M2 passed, but the expected Verdi FSDB was not generated." >&2
        exit 1
    fi
    cp waves/tinygpu_m2.fsdb "waves/tinygpu_m2_${run_tag}.fsdb"
fi
