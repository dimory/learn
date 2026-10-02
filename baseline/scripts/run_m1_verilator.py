#!/usr/bin/env python3
"""Optional M1 RTL regression using Verilator 5 with timing support."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--verilator',default='verilator')
    parser.add_argument('--verilator-root')
    args=parser.parse_args()
    (ROOT/'logs').mkdir(exist_ok=True)
    (ROOT/'build').mkdir(exist_ok=True)
    environment=os.environ.copy()
    if args.verilator_root:
        environment['VERILATOR_ROOT']=args.verilator_root
    command=[args.verilator,'--binary','--timing','--assert','-Wno-fatal','--top-module','tb_gpu',
        '-f','sim/filelist_rtl.f','-f','sim/filelist_tb.f','--Mdir','build/obj_m1','-j','2']
    result=subprocess.run(command,cwd=ROOT,env=environment,capture_output=True,text=True)
    (ROOT/'logs/m1_verilator_compile.log').write_text(result.stdout+result.stderr)
    if result.returncode:
        print(result.stderr[-4000:]);return 1
    run=subprocess.run([str(ROOT/'build/obj_m1/Vtb_gpu'),'+TEST=all'],cwd=ROOT,capture_output=True,text=True,timeout=60)
    transcript=run.stdout+run.stderr
    (ROOT/'logs/m1_regression.log').write_text(transcript)
    print(transcript)
    return 0 if run.returncode==0 and 'ALL 6 TESTS PASSED' in transcript and 'Legacy UOP opcode coverage 0-9 and F' in transcript else 1
if __name__=='__main__':
    sys.exit(main())
