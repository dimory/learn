#!/usr/bin/env python3
"""Small ISA reference model for checking TinyGPU Pattern expectations."""

from pathlib import Path
import sys
from typing import List


ROOT = Path(__file__).resolve().parents[1]
LANES = 4


def load_program(name: str) -> List[int]:
    return [int(word, 16) for word in (ROOT / "patterns" / name).read_text().split()]


def execute_block(program: List[int], memory: List[int], block_id: int, mask: List[bool]):
    registers = [[0] * 16 for _ in range(LANES)]
    nzp = [0] * LANES
    pc = 0
    divergence_seen = False
    instruction_count = 0

    for lane in range(LANES):
        registers[lane][13] = block_id & 0xFF
        registers[lane][14] = LANES
        registers[lane][15] = lane

    while instruction_count < 10000:
        if pc & 1:
            raise RuntimeError(f"unaligned byte PC 0x{pc:02x}")
        word_index = pc >> 1
        if word_index >= len(program):
            raise RuntimeError(f"PC 0x{pc:02x} is outside the Pattern")

        inst = program[word_index]
        opcode = (inst >> 12) & 0xF
        rd = (inst >> 8) & 0xF
        rs = (inst >> 4) & 0xF
        rt = inst & 0xF
        branch_mask = (inst >> 9) & 0x7
        immediate = inst & 0xFF
        lane_next_pc = []

        for lane in range(LANES):
            if not mask[lane]:
                lane_next_pc.append(pc + 2)
                continue

            reg = registers[lane]
            next_pc = (pc + 2) & 0xFF

            if opcode == 0x0:
                pass
            elif opcode == 0x1:
                if nzp[lane] & branch_mask:
                    next_pc = immediate
            elif opcode == 0x2:
                if reg[rs] < reg[rt]:
                    nzp[lane] = 0b100
                elif reg[rs] == reg[rt]:
                    nzp[lane] = 0b010
                else:
                    nzp[lane] = 0b001
            elif opcode == 0x3:
                if rd < 13:
                    reg[rd] = (reg[rs] + reg[rt]) & 0xFF
            elif opcode == 0x4:
                if rd < 13:
                    reg[rd] = (reg[rs] - reg[rt]) & 0xFF
            elif opcode == 0x5:
                if rd < 13:
                    reg[rd] = (reg[rs] * reg[rt]) & 0xFF
            elif opcode == 0x6:
                if reg[rt] == 0:
                    raise RuntimeError("division by zero")
                if rd < 13:
                    reg[rd] = (reg[rs] // reg[rt]) & 0xFF
            elif opcode == 0x7:
                if rd < 13:
                    reg[rd] = memory[reg[rs]]
            elif opcode == 0x8:
                memory[reg[rs]] = reg[rt]
            elif opcode == 0x9:
                if rd < 13:
                    reg[rd] = immediate
            elif opcode == 0xF:
                pass
            else:
                raise RuntimeError(f"unsupported opcode 0x{opcode:x}")

            lane_next_pc.append(next_pc)

        active_pcs = [lane_next_pc[lane] for lane in range(LANES) if mask[lane]]
        if len(set(active_pcs)) > 1:
            divergence_seen = True

        instruction_count += 1
        if opcode == 0xF:
            return divergence_seen

        pc = active_pcs[0]

    raise RuntimeError("reference model instruction timeout")


def execute_kernel(program_name: str, threads: int, memory: List[int]):
    program = load_program(program_name)
    divergence_seen = False
    blocks = (threads + LANES - 1) // LANES
    for block in range(blocks):
        mask = [(block * LANES + lane) < threads for lane in range(LANES)]
        divergence_seen |= execute_block(program, memory, block, mask)
    return divergence_seen


def expect(memory: List[int], address: int, expected: int, label: str):
    actual = memory[address]
    if actual != expected:
        raise AssertionError(
            f"{label}: address {address}, expected 0x{expected:02x}, actual 0x{actual:02x}"
        )


def test_mat_add(threads: int):
    memory = [0] * 256
    for i in range(8):
        memory[i] = i
        memory[8 + i] = i
        memory[16 + i] = 0xA5
    execute_kernel("mat_add.hex", threads, memory)
    for i in range(threads):
        expect(memory, 16 + i, 2 * i, "mat_add")
    for i in range(threads, 8):
        expect(memory, 16 + i, 0xA5, "partial_block")


def test_mat_mul():
    memory = [0] * 256
    memory[0:8] = [1, 2, 3, 4, 1, 2, 3, 4]
    execute_kernel("mat_mul.hex", 4, memory)
    for address, expected in zip(range(8, 12), [7, 10, 15, 22]):
        expect(memory, address, expected, "mat_mul")


def test_divergence():
    memory = [0] * 256
    divergence_seen = execute_kernel("divergence.hex", 4, memory)
    if not divergence_seen:
        raise AssertionError("divergence Pattern did not diverge")
    for address in range(32, 36):
        expect(memory, address, 0x11, "divergence Lane-0 path")


def test_bank_conflict():
    memory = [0] * 256
    memory[0], memory[4], memory[8], memory[12] = 10, 20, 30, 40
    execute_kernel("bank_conflict.hex", 4, memory)
    for address, expected in zip(range(64, 68), [10, 20, 30, 40]):
        expect(memory, address, expected, "bank_conflict")


def main() -> int:
    tests = [
        ("mat_add", lambda: test_mat_add(8)),
        ("partial_block", lambda: test_mat_add(6)),
        ("mat_mul", test_mat_mul),
        ("divergence", test_divergence),
        ("bank_conflict", test_bank_conflict),
    ]
    for name, test in tests:
        test()
        print(f"PASS: reference ISA model {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
