#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

test_name="${1:-all}"
mkdir -p build logs waves

vcs_args=(
    -full64
    -sverilog
    -timescale=1ns/1ns
    -debug_access+all
    -kdb
    -top tb_gpu
    -f sim/filelist_rtl.f
    -f sim/filelist_tb.f
    -o build/simv
    -l logs/compile.log
)

novas_root="${NOVAS_HOME:-${VERDI_HOME:-}}"
if [[ -n "$novas_root" ]]; then
    pli_dir="$novas_root/share/PLI/VCS/LINUX64"
    if [[ -f "$pli_dir/novas.tab" && -f "$pli_dir/pli.a" ]]; then
        vcs_args+=(
            +define+FSDB
            -P "$pli_dir/novas.tab" "$pli_dir/pli.a"
        )
    fi
fi

vcs "${vcs_args[@]}"

./build/simv \
    "+TEST=${test_name}" \
    -l "logs/sim_${test_name}.log"
