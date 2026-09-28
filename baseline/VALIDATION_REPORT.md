# TinyGPU baseline validation report

## Baseline scope

The RTL under `rtl/` is copied from `gpu1.zip` without functional rewrites,
except for the newly added structural integration module `rtl/gpu_top.sv`.
Files containing `old` are not copied into this baseline and do not appear in
either compile filelist.

Current architectural scope:

- One Core
- One resident Wave
- Four lanes per Wave
- One Wave per Block
- Blocking instruction execution and blocking LSU
- Synchronous instruction SRAM
- Four single-port synchronous data-SRAM banks
- Divergence detection only; lowest active Lane supplies the shared next PC

## Checks completed here

| Check | Result |
|---|---|
| RTL/TB filelist completeness | PASS |
| Exclusion of `*old*` files | PASS |
| Unique module definitions | PASS |
| Basic SV delimiter balance | PASS |
| All Pattern words exactly 16 bits | PASS |
| Byte-addressed branch-target conversion | PASS |
| Reference ISA `mat_add` | PASS |
| Reference ISA partial final Block | PASS |
| Reference ISA `mat_mul` | PASS |
| Reference ISA divergence behavior | PASS |
| Reference ISA bank-conflict Pattern | PASS |
| Shell-script syntax | PASS |
| Python-script syntax | PASS |

Commands used:

```bash
python3 scripts/preflight.py
python3 scripts/reference_iss.py
bash -n scripts/run_vcs.sh scripts/open_verdi.sh
python3 -m py_compile scripts/preflight.py scripts/reference_iss.py
```

## Manual RTL timing review

The following protocol relationships were checked against the current source:

1. Instruction fetch issues `imem_ce`, waits for synchronous SRAM `rdata`, then
   captures the instruction in a later Fetcher state.
2. Register operands are captured in `CORE_STATE_REQUEST` before ALU/LSU use.
3. ALU results are produced in `CORE_STATE_EXECUTE` and written back in
   `CORE_STATE_UPDATE`.
4. CMP NZP is saved during UPDATE and is available to a subsequent BRNZP.
5. Wave LSU retains an instruction mask and clears only lanes reported through
   `memory_done_mask`.
6. Each SRAM bank keeps in-flight lane/address/data/write metadata stable for
   the complete transaction lifecycle.
7. Read data is captured after the synchronous SRAM read edge, not on the issue
   edge.
8. Same-bank requests remain pending and are served one Lane at a time.
9. Dispatcher counts `core_done` only for a busy Core.
10. Final completion uses this cycle's completion cursor and `core_busy_next`,
    then asserts top-level `done` for the following full DONE-state cycle.

## VCS RTL regression

The executable regression is provided in `tb/tb_gpu.sv`. Run:

```bash
make sim
```

Required final log signature:

```text
TinyGPU baseline: ALL 6 TESTS PASSED
```

The six tests are `mat_add`, `partial_block`, `mat_mul`, `divergence`,
`bank_conflict`, and `zero_thread`.

The testbench is the final authority for RTL correctness. The reference ISA
model validates Pattern encoding and expected architectural results but does
not replace event-driven RTL simulation.

## Deferred architecture

The Dispatcher interface is shaped for several Cores, but this top is fixed to
one Core because the current instruction SRAM and Memory Subsystem each expose
one Core/Wave request port. Multi-Core support requires explicit instruction
delivery and shared-data-memory arbitration and is therefore a later upgrade,
not a parameter-only change.
