#!/usr/bin/env python3
"""Run the M2 whole-subsystem regression; no single-module tests are run."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--iverilog', default='iverilog')
    parser.add_argument('--vvp', default='vvp')
    parser.add_argument('--ivl-dir')
    parser.add_argument('--contexts', type=int, default=4)
    parser.add_argument('--wg', type=int, default=64)
    parser.add_argument('--matrix', action='store_true')
    parser.add_argument('--vcd', action='store_true')
    args = parser.parse_args()
    for tool in (args.iverilog, args.vvp):
        if shutil.which(tool) is None:
            parser.error('Executable not found: ' + tool)
    configs = ([(n,64) for n in (1,3,4,5,8)] + [(4,p) for p in (1,33,97)]) if args.matrix else [(args.contexts,args.wg)]
    for directory in ('build','logs','waves'):
        (ROOT/directory).mkdir(exist_ok=True)
    results = []
    for n,p in configs:
        label = 'm2_n%d_wg%d' % (n,p)
        output = ROOT/'build'/(label+'.vvp')
        compile_args = [args.iverilog]
        if args.ivl_dir:
            compile_args += ['-B', args.ivl_dir]
        compile_args += ['-g2012','-DM2_IVERILOG','-s','tb_wave_control_subsystem',
            '-DM2_NUM_CONTEXTS=%d' % n,'-DM2_WG_THREADS=%d' % p,
            '-f','sim/filelist_m2_rtl.f','-f','sim/filelist_m2_tb.f','-o',str(output)]
        compile_run = subprocess.run(compile_args, cwd=ROOT, capture_output=True, text=True, timeout=60)
        (ROOT/'logs'/(label+'_compile.log')).write_text(compile_run.stdout+compile_run.stderr)
        passed = False
        if compile_run.returncode == 0:
            run_args = [args.vvp]
            if args.ivl_dir:
                run_args += ['-M',args.ivl_dir]
            run_args += [str(output)]
            if args.vcd:
                run_args += ['+VCD']
            run = subprocess.run(run_args,cwd=ROOT,capture_output=True,text=True,timeout=60)
            transcript = run.stdout+run.stderr
            (ROOT/'logs'/(label+'.log')).write_text(transcript)
            passed = run.returncode == 0 and 'SCENARIO GROUPS PASSED' in transcript
            for line in transcript.splitlines():
                if line.startswith(('TinyGPU M2:', 'M2 COVERAGE')) or 'FATAL' in line:
                    print(line,flush=True)
        else:
            print(compile_run.stderr[-4000:],flush=True)
        results.append({'contexts':n,'threads_per_workgroup':p,'status':'PASS' if passed else 'FAIL','log':'logs/'+label+'.log'})
        if not passed:
            break
    (ROOT/'logs/m2_results.json').write_text(json.dumps(results,indent=2)+'\n')
    good = len(results)==len(configs) and all(r['status']=='PASS' for r in results)
    print('M2 matrix: %d/%d configurations passed' % (sum(r['status']=='PASS' for r in results),len(configs)),flush=True)
    return 0 if good else 1

if __name__=='__main__':
    sys.exit(main())
