#!/usr/bin/env bash
# Check the existing VCS/Verdi installation without compiling or using a license.
set -euo pipefail
status=0
for tool in vcs verdi; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "PASS: $tool = $(command -v "$tool")"
    else
        echo "FAIL: $tool is not in PATH; source your VCS2016/Verdi2016 setup." >&2
        status=1
    fi
done
novas_root="${NOVAS_HOME:-${VERDI_HOME:-}}"
if [[ -z "$novas_root" ]]; then
    echo "FAIL: set NOVAS_HOME or VERDI_HOME to the Verdi2016 installation." >&2
    status=1
else
    pli_dir="$novas_root/share/PLI/VCS/LINUX64"
    for file in novas.tab pli.a; do
        if [[ -r "$pli_dir/$file" ]]; then
            echo "PASS: readable $pli_dir/$file"
        else
            echo "FAIL: missing or unreadable $pli_dir/$file" >&2
            status=1
        fi
    done
fi
if [[ "$status" == 0 ]]; then
    echo "M2 tool paths and FSDB PLI files are ready. License and version checks occur on the actual tools."
fi
exit "$status"
