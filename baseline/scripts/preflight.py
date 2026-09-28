#!/usr/bin/env python3
"""Static project checks that do not replace RTL simulation."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]

EXPECTED_RTL = {
    "alu",
    "core",
    "decoder",
    "dispatcher",
    "gpu_top",
    "instruction_fetcher",
    "memory_backend",
    "memory_subsystem",
    "pc",
    "register_file",
    "scheduler",
    "single_port_sram",
    "wave_lsu",
}

PATTERN_LENGTHS = {
    "mat_add.hex": 13,
    "mat_mul.hex": 28,
    "divergence.hex": 14,
    "bank_conflict.hex": 7,
}


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    raise SystemExit(1)


def read_filelist(name: str) -> list[Path]:
    result = []
    for raw_line in (ROOT / "sim" / name).read_text().splitlines():
        line = raw_line.strip()
        if line and not line.startswith("#"):
            result.append(ROOT / line)
    return result


def check_filelists() -> None:
    rtl_files = read_filelist("filelist_rtl.f")
    tb_files = read_filelist("filelist_tb.f")
    all_files = rtl_files + tb_files

    for path in all_files:
        if not path.is_file():
            fail(f"filelist entry is missing: {path.relative_to(ROOT)}")

    if any("old" in path.name.lower() for path in all_files):
        fail("an old-named file is present in a compile filelist")

    modules: dict[str, Path] = {}
    module_re = re.compile(r"^\s*module\s+([A-Za-z_][A-Za-z0-9_]*)", re.M)
    for path in rtl_files:
        for module_name in module_re.findall(path.read_text()):
            if module_name in modules:
                fail(
                    f"duplicate module {module_name}: "
                    f"{modules[module_name].name}, {path.name}"
                )
            modules[module_name] = path

    missing = EXPECTED_RTL - set(modules)
    unexpected = set(modules) - EXPECTED_RTL
    if missing:
        fail(f"missing RTL modules: {sorted(missing)}")
    if unexpected:
        fail(f"unexpected RTL modules: {sorted(unexpected)}")

    print("PASS: RTL and testbench filelists are complete")
    print("PASS: files containing 'old' are excluded")
    print("PASS: RTL module names are unique")


def check_patterns() -> None:
    for filename, expected_length in PATTERN_LENGTHS.items():
        path = ROOT / "patterns" / filename
        words = [line.strip() for line in path.read_text().splitlines() if line.strip()]
        if len(words) != expected_length:
            fail(f"{filename} contains {len(words)} words, expected {expected_length}")
        for index, word in enumerate(words):
            if not re.fullmatch(r"[0-9a-fA-F]{4}", word):
                fail(f"{filename}:{index + 1} is not one 16-bit hex word")

    mat_mul = [
        int(word, 16)
        for word in (ROOT / "patterns" / "mat_mul.hex").read_text().split()
    ]
    divergence = [
        int(word, 16)
        for word in (ROOT / "patterns" / "divergence.hex").read_text().split()
    ]

    if mat_mul[24] != 0x1818:
        fail("mat_mul loop branch must target byte address 0x18")
    if divergence[4] != 0x1810:
        fail("divergence BRn must target byte address 0x10")
    if divergence[6] != 0x1E14 or divergence[9] != 0x1E14:
        fail("divergence join branches must target byte address 0x14")

    print("PASS: all Pattern words are exactly 16 bits")
    print("PASS: absolute branch targets use byte addresses")


def check_basic_sv_balance() -> None:
    for path in read_filelist("filelist_rtl.f") + read_filelist("filelist_tb.f"):
        text = path.read_text()
        module_count = len(re.findall(r"^\s*module\b", text, re.M))
        endmodule_count = len(re.findall(r"^\s*endmodule\b", text, re.M))
        if module_count != endmodule_count:
            fail(f"module/endmodule mismatch in {path.relative_to(ROOT)}")
        if text.count("(") != text.count(")"):
            fail(f"parenthesis mismatch in {path.relative_to(ROOT)}")
        if text.count("[") != text.count("]"):
            fail(f"bracket mismatch in {path.relative_to(ROOT)}")
    print("PASS: basic SystemVerilog delimiter checks")


def main() -> int:
    check_filelists()
    check_patterns()
    check_basic_sv_balance()
    print("PASS: static preflight completed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
