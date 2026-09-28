# TinyGPU baseline patterns

All PCs and branch targets are byte addresses. Instructions remain 16-bit
words in the instruction SRAM, so sequential PCs advance by two.

| Pattern | Threads | Purpose |
|---|---:|---|
| `mat_add.hex` | 8 or 6 | Two sequential Blocks, loads, ADD, stores, partial final Wave |
| `mat_mul.hex` | 4 | 2x2 matrix multiply, loop, MUL/DIV/SUB/CMP/BRNZP |
| `divergence.hex` | 4 | Per-lane branch disagreement; baseline follows Lane 0 |
| `bank_conflict.hex` | 4 | Four loads to addresses 0/4/8/12, all targeting Bank 0 |

## Byte-address conversion

The old word-PC matrix-multiply loop used target instruction index 12. Its new
absolute byte target is `12 * 2 = 24 = 8'h18`, therefore the BRn instruction is
`16'h1818`.

The divergence program similarly converts word targets 8 and 10 into byte
targets `8'h10` and `8'h14`.

## Divergence expectation

At the conditional BRn:

- Lane 0/1 request byte PC `8'h10`.
- Lane 2/3 request sequential byte PC `8'h0a`.
- The current Scheduler detects the mismatch and selects the lowest active
  lane, so all lanes subsequently execute the Lane-0 path.
- Output bytes 32 through 35 are therefore all `8'h11`.

This verifies detection only. It does not claim full divergent-path execution.
