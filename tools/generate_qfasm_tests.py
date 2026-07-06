#!/usr/bin/env python3
"""Generate the Stage 1 assembler test fixtures under tests/cases/.

Three fixture families, all deterministic:

- qfasm-exit42: minimal program with labels and a short jump.
- qfasm-arith: random 32-bit add/sub cases in nybble-list form, with the
  expected printed results.
- qfasm-big: a large randomized program (about 8 KiB of code, far beyond the
  old finite-table assembler's range) covering every instruction category.

Expected bytes come from the independent Python model below, not from the
assembler, so these are true differential tests.

Run: python3 tools/generate_qfasm_tests.py
"""

import os
import random
import struct

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CASES = os.path.join(ROOT, "tests", "cases")

HEX = "0123456789ABCDEF"
REGS = ["EAX", "ECX", "EDX", "EBX", "ESP", "EBP", "ESI", "EDI"]
RN = {r: i for i, r in enumerate(REGS)}
GP = ["EAX", "ECX", "EDX", "EBX", "ESI", "EDI"]
BASE01 = ["EAX", "ECX", "EDX", "EBX", "EBP", "ESI", "EDI"]
BASE00 = ["EAX", "ECX", "EDX", "EBX", "ESI", "EDI"]
VBASE = 0x08048058


def x8(v):
    return "(X8 " + " ".join(f"{(v >> (28 - 4 * i)) & 15:X}"
                             for i in range(8)) + ")"


def n_form(v):
    return "(N " + " ".join(HEX[(v >> (4 * i)) & 15] for i in range(8)) + ")"


def write(path, data):
    mode = "wb" if isinstance(data, bytes) else "w"
    with open(os.path.join(CASES, path), mode) as f:
        f.write(data)


def hexdump(data):
    return "".join(" ".join(f"{b:02x}" for b in data[i:i + 16]) + "\n"
                   for i in range(0, len(data), 16))


def elf(entryoff, code, bss=0):
    hdr = b"\x7fELF" + bytes([1, 1, 1, 0]) + b"\x00" * 8
    hdr += struct.pack("<HHI", 2, 3, 1)
    hdr += struct.pack("<I", VBASE + entryoff)
    hdr += struct.pack("<III", 0x34, 0, 0)
    hdr += struct.pack("<HHHHHH", 0x34, 0x20, 1, 0, 0, 0)
    hdr += struct.pack("<IIII", 1, 0, 0x08048000, 0x08048000)
    hdr += struct.pack("<III", 0x58 + len(code), 0x58 + len(code) + bss, 7)
    hdr += struct.pack("<I", 0x1000)
    return hdr + b"\x00" * 4 + code


def program(items, bss=0):
    """items: (sexp, size, fn) with fn(labels, pc) -> bytes, or None for
    labels, or the strings "align4"/"align8"."""
    labels, pc = {}, 0
    for sexp, size, fn in items:
        if sexp.startswith("(Label"):
            labels[sexp[7:-1]] = pc
        elif fn == "align4":
            pc += (4 - pc % 4) % 4
        elif fn == "align8":
            pc += (8 - pc % 8) % 8
        else:
            pc += size
    out, pc2 = b"", 0
    for sexp, size, fn in items:
        if sexp.startswith("(Label"):
            continue
        if fn == "align4":
            n = (4 - pc2 % 4) % 4
            out += b"\x00" * n
            pc2 += n
        elif fn == "align8":
            n = (8 - pc2 % 8) % 8
            out += b"\x00" * n
            pc2 += n
        else:
            out += fn(labels, pc2)
            pc2 += size
    src = ["(Assemble (Program Entry " + x8(bss)]
    for sexp, _, _ in items:
        src.append("  (Ins " + sexp)
    src.append("  End" + ")" * len(items) + "))")
    return "\n".join(src) + "\n", elf(labels["Entry"], out, bss)


def gen_exit42():
    items = [
        ("(Label Entry)", 0, None),
        ("(MovRI EAX (X8 0 0 0 0 0 0 0 1))", 5,
         lambda L, pc: b"\xB8\x01\x00\x00\x00"),
        ("(JmpS Skip)", 2, lambda L, pc: bytes([0xEB, (L["Skip"] - (pc + 2))
                                                & 0xFF])),
        ("(Db DE)", 1, lambda L, pc: b"\xDE"),
        ("(Label Skip)", 0, None),
        ("(MovRI EBX (X8 0 0 0 0 0 0 2 A))", 5,
         lambda L, pc: b"\xBB\x2A\x00\x00\x00"),
        ("(Int 80)", 2, lambda L, pc: b"\xCD\x80"),
    ]
    src, binary = program(items)
    write("qfasm-exit42.qfasm", src)
    write("qfasm-exit42.hex", hexdump(binary))
    write("qfasm-exit42.status", "42\n")


def gen_arith():
    random.seed(7)
    lines, expect = [], []
    for _ in range(40):
        a, b = random.getrandbits(32), random.getrandbits(32)
        lines += [f"(Add32 {n_form(a)} {n_form(b)})",
                  f"(Sub32 {n_form(a)} {n_form(b)})"]
        expect += [n_form((a + b) % 2**32), n_form((a - b) % 2**32)]
    write("qfasm-arith.qfasm", "\n".join(lines) + "\n")
    write("qfasm-arith.out", "\n".join(expect) + "\n")


def gen_big():
    random.seed(42)
    items = []

    def add(sexp, size, fn):
        items.append((sexp, size, fn))

    def fixed(sexp, bs):
        add(sexp, len(bs), lambda L, pc, bs=bs: bs)

    nblocks = 80
    for k in range(nblocks):
        add(f"(Label (B {k}))", 0, None)
        r1, r2 = random.sample(GP, 2)
        imm = random.getrandbits(32)
        fixed(f"(MovRI {r1} {x8(imm)})",
              bytes([0xB8 + RN[r1]]) + struct.pack("<I", imm))
        fixed(f"(MovRR {r2} {r1})",
              bytes([0x89, 0xC0 | (RN[r1] << 3) | RN[r2]]))
        op8 = random.choice([("AddI8", 0), ("OrI8", 1), ("AndI8", 4),
                             ("SubI8", 5), ("XorI8", 6), ("CmpI8", 7)])
        b8 = random.randrange(256)
        fixed(f"({op8[0]} {r1} {b8:02X})",
              bytes([0x83, 0xC0 | (op8[1] << 3) | RN[r1], b8]))
        sh = random.choice([("ShlI8", 4), ("ShrI8", 5), ("SarI8", 7)])
        shn = random.randrange(1, 31)
        fixed(f"({sh[0]} {r2} {shn:02X})",
              bytes([0xC1, 0xC0 | (sh[1] << 3) | RN[r2], shn]))
        un = random.choice([("NotR", 2), ("NegR", 3)])
        fixed(f"({un[0]} {r1})", bytes([0xF7, 0xC0 | (un[1] << 3) | RN[r1]]))
        rr = random.choice([("AddRR", 0x01), ("SubRR", 0x29),
                            ("CmpRR", 0x39), ("XorRR", 0x31),
                            ("OrRR", 0x09), ("AndRR", 0x21),
                            ("TestRR", 0x85)])
        fixed(f"({rr[0]} {r1} {r2})",
              bytes([rr[1], 0xC0 | (RN[r2] << 3) | RN[r1]]))
        i32 = random.choice([("AddI32", 0), ("AndI32", 4), ("SubI32", 5),
                             ("CmpI32", 7)])
        v32 = random.getrandbits(32)
        fixed(f"({i32[0]} {r2} {x8(v32)})",
              bytes([0x81, 0xC0 | (i32[1] << 3) | RN[r2]])
              + struct.pack("<I", v32))
        fixed(f"(PushR {r1})", bytes([0x50 + RN[r1]]))
        fixed(f"(PopR {r1})", bytes([0x58 + RN[r1]]))
        fixed(f"(IncR {r2})", bytes([0x40 + RN[r2]]))
        fixed(f"(DecR {r2})", bytes([0x48 + RN[r2]]))
        b0, b1 = random.choice(BASE00), random.choice(BASE01)
        d8 = random.randrange(0, 128)
        rm = random.choice([r for r in GP if r != b0])
        fixed(f"(MovRM {rm} {b0})", bytes([0x8B, (RN[rm] << 3) | RN[b0]]))
        fixed(f"(MovMR {b0} {rm})", bytes([0x89, (RN[rm] << 3) | RN[b0]]))
        fixed(f"(MovRMD {rm} {b1} {d8:02X})",
              bytes([0x8B, 0x40 | (RN[rm] << 3) | RN[b1], d8]))
        fixed(f"(MovMDR {b1} {d8:02X} {rm})",
              bytes([0x89, 0x40 | (RN[rm] << 3) | RN[b1], d8]))
        fixed(f"(MovzxRMb {rm} {b0})",
              bytes([0x0F, 0xB6, (RN[rm] << 3) | RN[b0]]))
        fixed(f"(MovbMR {b0} {rm})", bytes([0x88, (RN[rm] << 3) | RN[b0]]))
        fixed(f"(LeaRMD {rm} {b1} {d8:02X})",
              bytes([0x8D, 0x40 | (RN[rm] << 3) | RN[b1], d8]))
        dl = f"(D {random.randrange(nblocks)})"
        add(f"(MovRMemL {rm} {dl})", 6,
            lambda L, pc, rm=rm, dl=dl: bytes([0x8B, (RN[rm] << 3) | 5])
            + struct.pack("<I", VBASE + L[dl]))
        add(f"(MovRILabel {rm} {dl})", 5,
            lambda L, pc, rm=rm, dl=dl: bytes([0xB8 + RN[rm]])
            + struct.pack("<I", VBASE + L[dl]))
        add(f"(MovRIConst {rm} {dl})", 5,
            lambda L, pc, rm=rm, dl=dl: bytes([0xB8 + RN[rm]])
            + struct.pack("<I", VBASE + 1 + L[dl]))
        add(f"(CmpEaxLabel {dl})", 5,
            lambda L, pc, dl=dl: b"\x3D" + struct.pack("<I", VBASE + L[dl]))
        sj = random.choice([("Jz", 0x74), ("Jnz", 0x75), ("Jb", 0x72),
                            ("Jae", 0x73), ("Jbe", 0x76), ("Ja", 0x77),
                            ("Js", 0x78), ("Jns", 0x79), ("Jl", 0x7C),
                            ("Jge", 0x7D), ("Jle", 0x7E), ("Jg", 0x7F),
                            ("JmpS", 0xEB)])
        lbl = f"(S {k})"
        add(f"({sj[0]} {lbl})", 2,
            lambda L, pc, op=sj[1], lbl=lbl:
            bytes([op, (L[lbl] - (pc + 2)) & 0xFF]))
        fixed("(Db DE)", b"\xDE")
        add(f"(Label {lbl})", 0, None)
        tb = f"(B {random.randrange(nblocks)})"
        cc = random.choice([("Jz32", 0x84), ("Jnz32", 0x85), ("Jb32", 0x82),
                            ("Jae32", 0x83), ("Jbe32", 0x86), ("Ja32", 0x87),
                            ("Jl32", 0x8C), ("Jge32", 0x8D), ("Jle32", 0x8E),
                            ("Jg32", 0x8F)])
        lbl2 = f"(T {k})"
        add(f"(JmpS {lbl2})", 2,
            lambda L, pc, lbl2=lbl2:
            bytes([0xEB, (L[lbl2] - (pc + 2)) & 0xFF]))
        add(f"({cc[0]} {tb})", 6,
            lambda L, pc, op=cc[1], tb=tb: bytes([0x0F, op])
            + struct.pack("<i", L[tb] - (pc + 6)))
        add(f"(Call (Fn {k % 7}))", 5,
            lambda L, pc, k=k: b"\xE8"
            + struct.pack("<i", L[f"(Fn {k % 7})"] - (pc + 5)))
        add(f"(Label {lbl2})", 0, None)
        if k % 3 == 0:
            add("(Align4)", None, "align4")
        if k % 7 == 0:
            add("(Align8)", None, "align8")

    add("(Jmp32 Done)", 5,
        lambda L, pc: b"\xE9" + struct.pack("<i", L["Done"] - (pc + 5)))
    for f in range(7):
        add(f"(Label (Fn {f}))", 0, None)
        fixed("(Nop)", b"\x90")
        fixed("(Ret)", b"\xC3")
    add("(Align4)", None, "align4")
    for k in range(nblocks):
        add(f"(Label (D {k}))", 0, None)
        v = random.getrandbits(32)
        fixed(f"(Dd {x8(v)})", struct.pack("<I", v))
        add(f"(DLabel (B {k}))", 4,
            lambda L, pc, k=k: struct.pack("<I", VBASE + L[f"(B {k})"]))
        add(f"(DConst (B {k}))", 4,
            lambda L, pc, k=k: struct.pack("<I", VBASE + 1 + L[f"(B {k})"]))
        fixed("(DNil)", b"\x01\x00\x00\x00")
    add("(Label Done)", 0, None)
    fixed(f"(MovRI EAX {x8(1)})", b"\xB8\x01\x00\x00\x00")
    fixed(f"(MovRI EBX {x8(0x2A)})", b"\xBB\x2A\x00\x00\x00")
    fixed("(Int 80)", b"\xCD\x80")
    items.insert(0, ("(Label Entry)", 0, None))
    items.insert(1, ("(Jmp32 Done)", 5,
                     lambda L, pc: b"\xE9"
                     + struct.pack("<i", L["Done"] - (pc + 5))))

    src, binary = program(items, bss=1 << 20)
    write("qfasm-big.qfasm", src)
    write("qfasm-big.hex", hexdump(binary))
    write("qfasm-big.status", "42\n")


def main():
    gen_exit42()
    gen_arith()
    gen_big()
    print("wrote qfasm-exit42, qfasm-arith, qfasm-big fixtures")


if __name__ == "__main__":
    main()
