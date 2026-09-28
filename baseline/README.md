# TinyGPU M1 CDNA5 upgrade baseline

This package integrates the current rewritten TinyGPU RTL as a synthesizable
single-Core baseline and keeps all verification code in a separate directory.
Files whose names contain `old` are deliberately excluded.

M1 adds a CDNA-oriented common Micro-op definition and a compatibility Adapter
for the original 16-bit ISA. The original execution datapath is unchanged, so
all baseline programs continue to execute through the proven Legacy controls.

## Directory structure

```text
rtl/       Synthesizable design, gpu_pkg, Legacy Adapter and gpu_top
tb/        Self-checking environment and independent UOP checker
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

## M1 compatibility bridge

`rtl/gpu_pkg.sv` establishes the common architectural vocabulary used by later
milestones: Wave32, 32-bit register elements, 64-bit byte addresses, instruction
formats, execution classes, operand kinds, memory properties and the packed
`decoded_uop_t` bundle.

`rtl/legacy_decode_adapter.sv` translates the registered output of the existing
16-bit Decoder into `decoded_uop_t` during `CORE_STATE_REQUEST`. It is a
combinational observation path in M1; it neither controls the Core nor changes
instruction timing. Later CDNA decoders can produce the same bundle without
requiring every downstream block to understand instruction bit fields.

`tb/legacy_uop_checker.sv` independently checks the Adapter mapping for NOP,
BRNZP, CMP, ADD, SUB, MUL, DIV, LDR, STR, CONST and RET. A full regression also
requires coverage of opcodes 0 through 9 and F.

The M1 data path is therefore:

```text
Legacy instruction -> Legacy Decoder -> original execution controls
                                  +---> Legacy Adapter -> decoded_uop_t
```

Only the first path drives execution in M1. `decoded_uop_t` is the stable
handoff contract that M2 and later CDNA-oriented blocks will consume.

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

It must also contain:

```text
[PASS] Legacy UOP opcode coverage 0-9 and F
```

Reference-model success is useful for validating Pattern encoding and expected
results, but it does not replace the VCS RTL simulation.
