#!/usr/bin/env bash
# Final acceptance matrix for the user's VCS2016 environment.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p logs
summary=logs/m2_vcs_matrix.log
: > "$summary"
configs=("1 64" "3 64" "4 64" "5 64" "8 64" "4 1" "4 33" "4 97")
for config in "${configs[@]}"; do
    read -r contexts wg_threads <<< "$config"
    echo "VCS2016 M2: N=${contexts} WG=${wg_threads}" | tee -a "$summary"
    if ! ./scripts/run_m2_vcs.sh "$contexts" "$wg_threads"; then
        echo "FAIL N=${contexts} WG=${wg_threads}" | tee -a "$summary"
        exit 1
    fi
    grep -E '^TinyGPU M2: ALL ' "logs/m2_vcs_n${contexts}_wg${wg_threads}.log" | tee -a "$summary"
done
echo "M2 VCS matrix: 8/8 configurations passed" | tee -a "$summary"
