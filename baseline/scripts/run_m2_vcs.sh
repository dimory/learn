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
config_tag="n${contexts}_wg${wg_threads}"
if [[ "$scenario" == 0 ]]; then
    run_tag="$config_tag"
else
    run_tag="${config_tag}_s${scenario}"
fi
if ! command -v vcs >/dev/null 2>&1; then
    echo "VCS is not in PATH. Source your VCS2016 setup, then run make m2_env." >&2
    exit 127
fi
require_fsdb="${M2_REQUIRE_FSDB:-1}"
if [[ "$require_fsdb" != 0 && "$require_fsdb" != 1 ]]; then
    echo "M2_REQUIRE_FSDB must be 0 or 1." >&2
    exit 2
fi
mkdir -p build logs waves
# VCS2016/Verdi2016 are the final acceptance tools. This script uses their
# existing PATH entries; it neither downloads nor substitutes a simulator.
vcs_args=(
    -full64 -lca -sverilog -timescale=1ns/1ns -debug_access+all -kdb
    "+define+M2_NUM_CONTEXTS=${contexts}" "+define+M2_WG_THREADS=${wg_threads}"
    -top tb_wave_control_subsystem
    -f sim/filelist_m2_rtl.f -f sim/filelist_m2_tb.f
    "-Mdir=build/csrc_m2_${config_tag}"
    -o "build/simv_m2_${config_tag}" -l "logs/m2_vcs_${config_tag}_compile.log"
)
novas_root="${NOVAS_HOME:-${VERDI_HOME:-}}"
fsdb_enabled=0
if [[ -n "$novas_root" ]]; then
    pli_dir="$novas_root/share/PLI/VCS/LINUX64"
    if [[ -r "$pli_dir/novas.tab" && -r "$pli_dir/pli.a" ]]; then
        vcs_args+=(+define+FSDB -P "$pli_dir/novas.tab" "$pli_dir/pli.a")
        fsdb_enabled=1
    fi
fi
if [[ "$fsdb_enabled" == 0 ]]; then
    if [[ "$require_fsdb" == 1 ]]; then
        echo "FSDB PLI unavailable: set NOVAS_HOME or VERDI_HOME to your Verdi2016 installation." >&2
        echo "Required files: share/PLI/VCS/LINUX64/novas.tab and pli.a." >&2
        echo "Use M2_REQUIRE_FSDB=0 only for a simulation without Verdi waveform acceptance." >&2
        exit 2
    fi
    echo "FSDB disabled: set NOVAS_HOME or VERDI_HOME to your Verdi2016 installation."
fi
rm -f "logs/m2_vcs_${config_tag}_compile.log" "logs/m2_vcs_${run_tag}.log" \
    "waves/tinygpu_m2_${run_tag}.fsdb"
vcs "${vcs_args[@]}"
if [[ "$fsdb_enabled" == 1 ]]; then
    rm -f waves/tinygpu_m2.fsdb
fi
sim_args=(-l "logs/m2_vcs_${run_tag}.log")
if [[ "$scenario" != 0 ]]; then
    sim_args+=("+M2_SCENARIO=${scenario}")
fi
"./build/simv_m2_${config_tag}" "${sim_args[@]}"
if [[ "$scenario" == 0 ]]; then
    if ! grep -Eq "TinyGPU M2: ALL [0-9]+ SCENARIO GROUPS PASSED N=${contexts} WG=${wg_threads} " "logs/m2_vcs_${run_tag}.log"; then
        echo "M2 failed: missing complete regression PASS signature." >&2
        exit 1
    fi
else
    if ! grep -Eq "TinyGPU M2: SCENARIO ${scenario} PASSED N=${contexts} WG=${wg_threads} " "logs/m2_vcs_${run_tag}.log"; then
        echo "M2 scenario ${scenario} failed: missing single-scenario PASS signature." >&2
        exit 1
    fi
fi
if [[ "$fsdb_enabled" == 1 ]]; then
    if [[ ! -s waves/tinygpu_m2.fsdb ]]; then
        echo "M2 passed, but the expected Verdi FSDB was not generated." >&2
        exit 1
    fi
    cp waves/tinygpu_m2.fsdb "waves/tinygpu_m2_${run_tag}.fsdb"
    if [[ "$scenario" == 0 ]]; then
        echo "M2 PASS: N=${contexts} WG=${wg_threads}; FSDB=waves/tinygpu_m2_${run_tag}.fsdb"
    else
        echo "M2 SCENARIO ${scenario} PASS: N=${contexts} WG=${wg_threads}; FSDB=waves/tinygpu_m2_${run_tag}.fsdb"
    fi
fi
