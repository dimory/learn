# TinyGPU synchronous-SRAM baseline

This package integrates the current rewritten TinyGPU RTL as a synthesizable
single-Core baseline and keeps all verification code in a separate directory.
Files whose names contain `old` are deliberately excluded.

## Directory structure

```text
rtl/       Synthesizable design and gpu_top.sv
tb/        Self-checking SystemVerilog verification environment
patterns/  16-bit instruction images with byte-addressed branch targets
sim/       Separate RTL and testbench filelists
scripts/   VCS/Verdi launch and static/reference checks
build/     Generated simulator executable
logs/      Compile and simulation logs
waves/     Generated FSDB
```

## Baseline configuration

- One Core
- Four lanes per Wave
- One Wave per Block
- Byte-addressed 8-bit PC
- 16-bit instructions and synchronous instruction SRAM
- 8-bit logical data memory split across four single-port SRAM banks
- Blocking Wave LSU
- Divergence detection with lowest-active-Lane PC selection

The single-Core restriction is intentional. Increasing Core count requires an
instruction/data-memory interconnect and is not a pure parameter change.

## Verification flow

Run checks that do not require an HDL simulator:

```bash
make preflight
make reference
```

Compile and run all RTL tests with VCS:

```bash
make sim
```

Run one Pattern:

```bash
make mat_add
make partial_block
make mat_mul
make divergence
make bank_conflict
make zero_thread
```

Open the generated FSDB with Verdi:

```bash
make verdi
```

`scripts/run_vcs.sh` supports VCS2016 syntax. If `NOVAS_HOME` or `VERDI_HOME`
points to Verdi2016 and its VCS PLI files are present, FSDB support is enabled
automatically.

## Pass criterion

The simulation log must end with:

```text
TinyGPU baseline: ALL 6 TESTS PASSED
```

Reference-model success is useful for validating Pattern encoding and expected
results, but it does not replace the VCS RTL simulation.
