#!/usr/bin/env python3
"""Generate bootstrap/qfasm.qf1, the general Qfitzah-hosted i386 assembler.

The assembler works on 32-bit numbers represented as little-endian nybble
lists, (N d0 d1 d2 d3 d4 d5 d6 d7) for d0 + 16*d1 + ... + 16^7*d7, with
uppercase hex digit atoms. All arithmetic is add/negate over generated
single-nybble fact tables, so there are no finite range tables: label
arithmetic, rel8/rel32 offsets, and ELF header fields work for programs of
any size. Byte atoms (what the seed's (Bytes ...) output path consumes) are
produced by the generated (HB hi lo) table because the seed cannot synthesize
new atoms at runtime.

Programs are data:

  (Assemble (Program entry (X8 0 0 1 0 0 0 0 0) code))

where the X8 form (eight big-endian hex digits, here 1 MiB) is the extra
zero-initialized memory (bss) appended to the single RWE load segment, and
code is a right-nested (Ins instr (Ins ... End)) chain. Label names may be arbitrary terms, e.g. (Local Scope 1), because the
symbol table compares keys structurally.

Run: python3 tools/generate_qfasm.py > bootstrap/qfasm.qf1
"""

import sys

HEX = "0123456789ABCDEF"
REGS = ["EAX", "ECX", "EDX", "EBX", "ESP", "EBP", "ESI", "EDI"]
REGNUM = {r: i for i, r in enumerate(REGS)}

out = []


def rule(pat, tmpl):
    out.append(f"{pat} {tmpl}")


def hexbyte(n):
    return f"{n:02X}"


def section(title):
    out.append("")
    out.append(f"; {title}")


# ---------------------------------------------------------------------------
# Fact tables (oldest rules, scanned last).
# ---------------------------------------------------------------------------

section("Single-nybble add with carry in: (AD carry a b) -> (P sum carry').")
for cin, cname in ((0, "O"), (1, "I")):
    for a in range(16):
        for b in range(16):
            s = a + b + cin
            rule(f"(AD {cname} {HEX[a]} {HEX[b]})",
                 f"(P {HEX[s % 16]} {'I' if s >= 16 else 'O'})")

section("Nybble complement: (ND d) -> 15 - d.")
for d in range(16):
    rule(f"(ND {HEX[d]})", HEX[15 - d])

section("Nybble pair to byte atom: (HB hi lo) -> byte.")
for hi in range(16):
    for lo in range(16):
        rule(f"(HB {HEX[hi]} {HEX[lo]})", f"{HEX[hi]}{HEX[lo]}")

section("ModRM mod=11 (register-register): (RM11 reg rm) -> byte.")
for r in REGS:
    for m in REGS:
        rule(f"(RM11 {r} {m})", hexbyte(0xC0 | (REGNUM[r] << 3) | REGNUM[m]))

section("ModRM mod=00 ([base]): (RM00 base reg) -> byte (no ESP/EBP base).")
for b in REGS:
    if b in ("ESP", "EBP"):
        continue
    for r in REGS:
        rule(f"(RM00 {b} {r})", hexbyte((REGNUM[r] << 3) | REGNUM[b]))

section("ModRM mod=01 ([base+disp8]): (RM01 base reg) -> byte (no ESP base).")
for b in REGS:
    if b == "ESP":
        continue
    for r in REGS:
        rule(f"(RM01 {b} {r})", hexbyte(0x40 | (REGNUM[r] << 3) | REGNUM[b]))

section("ModRM mod=00 rm=101 (absolute disp32): (RM05 reg) -> byte.")
for r in REGS:
    rule(f"(RM05 {r})", hexbyte((REGNUM[r] << 3) | 0x05))

section("Opcode-extension ModRM mod=11: (RMX ext reg) -> byte.")
for n in range(8):
    for r in REGS:
        rule(f"(RMX {n} {r})", hexbyte(0xC0 | (n << 3) | REGNUM[r]))

section("One-byte opcode+reg encodings.")
for base, name in ((0x40, "IncB"), (0x48, "DecB"), (0x50, "PushB"),
                   (0x58, "PopB"), (0xB8, "MovIB"), (0x90, "XchgAB")):
    for r in REGS:
        rule(f"({name} {r})", hexbyte(base + REGNUM[r]))

section("Alignment pad from the low nybble: (PadDig4 d), (PadDig8 d).")
for d in range(16):
    rule(f"(PadDig4 {HEX[d]})", HEX[(4 - d % 4) % 4])
for d in range(16):
    rule(f"(PadDig8 {HEX[d]})", HEX[(8 - d % 8) % 8])

section("Rel8 range guards: high nybble of an in-range offset byte.")
for d in range(8):
    rule(f"(R8P {HEX[d]})", "OK")
for d in range(8, 16):
    rule(f"(R8N {HEX[d]})", "OK")

# ---------------------------------------------------------------------------
# 32-bit arithmetic over nybble lists.
# ---------------------------------------------------------------------------

section("Number sugar: big-endian X8 literals and small constants.")
rule("(X8 a b c d e f g h)", "(N h g f e d c b a)")
for d in range(16):
    rule(f"(Small {HEX[d]})", f"(N {HEX[d]} 0 0 0 0 0 0 0)")

section("32-bit add (wraps mod 2^32): digit-chained through (AD ...).")
A = ["a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7"]
B = ["b0", "b1", "b2", "b3", "b4", "b5", "b6", "b7"]
S = ["s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7"]
rule(f"(Add32 (N {' '.join(A)}) (N {' '.join(B)}))",
     f"(A1 (AD O a0 b0) {' '.join(x for p in zip(A[1:], B[1:]) for x in p)})")
for i in range(1, 8):
    sums_lhs = "".join(s + " " for s in S[:i - 1])
    pairs_lhs = "".join(" " + x for p in zip(A[i:], B[i:]) for x in p)
    pairs_rhs = "".join(" " + x for p in zip(A[i + 1:], B[i + 1:]) for x in p)
    rule(f"(A{i} {sums_lhs}(P s{i - 1} c){pairs_lhs})",
         f"(A{i + 1} {' '.join(S[:i])} (AD c a{i} b{i}){pairs_rhs})")
rule("(A8 s0 s1 s2 s3 s4 s5 s6 (P s7 c))",
     "(N s0 s1 s2 s3 s4 s5 s6 s7)")

section("Negate and subtract.")
rule("(Neg32 (N a0 a1 a2 a3 a4 a5 a6 a7))",
     "(Add32 (N (ND a0) (ND a1) (ND a2) (ND a3) (ND a4) (ND a5) (ND a6)"
     " (ND a7)) (Small 1))")
rule("(Sub32 x y)", "(Add32 x (Neg32 y))")

section("Byte emission from numbers.")
rule("(LEB (N d0 d1 d2 d3 d4 d5 d6 d7))",
     "(Bytes (HB d1 d0) (HB d3 d2) (HB d5 d4) (HB d7 d6))")
rule("(LowByte (N d0 d1 d2 d3 d4 d5 d6 d7))", "(HB d1 d0)")

section("Checked rel8: in-range offsets only, else the term stays stuck.")
rule("(Rel8 (N d0 d1 0 0 0 0 0 0))", "(R8Ck (R8P d1) (HB d1 d0))")
rule("(Rel8 (N d0 d1 F F F F F F))", "(R8Ck (R8N d1) (HB d1 d0))")
rule("(R8Ck OK b)", "b")

section("Alignment padding.")
rule("(Pad4 (N d0 d1 d2 d3 d4 d5 d6 d7))", "(Small (PadDig4 d0))")
rule("(Pad8 (N d0 d1 d2 d3 d4 d5 d6 d7))", "(Small (PadDig8 d0))")
rule("(PadOut (N 0 0 0 0 0 0 0 0))", "(Bytes)")
rule("(PadOut (N 1 0 0 0 0 0 0 0))", "(Bytes 00)")
rule("(PadOut (N 2 0 0 0 0 0 0 0))", "(Bytes 00 00)")
rule("(PadOut (N 3 0 0 0 0 0 0 0))", "(Bytes 00 00 00)")
rule("(PadOut (N 4 0 0 0 0 0 0 0))", "(Bytes 00 00 00 00)")
rule("(PadOut (N 5 0 0 0 0 0 0 0))", "(Bytes 00 00 00 00 00)")
rule("(PadOut (N 6 0 0 0 0 0 0 0))", "(Bytes 00 00 00 00 00 00)")
rule("(PadOut (N 7 0 0 0 0 0 0 0))", "(Bytes 00 00 00 00 00 00 00)")

# ---------------------------------------------------------------------------
# Instruction set. Each entry generates a consistent (Size ...) and
# (Pass2 ...) rule pair, so sizes and emissions cannot drift apart.
#
# spec forms:
#   ("Name", args, size, emit_template)
# where emit_template is the (Bytes ...) body with {pc2} available as the
# post-instruction pc expression. Label-relative and symbol-using templates
# reference sym/pc directly.
# ---------------------------------------------------------------------------

INSTRUCTIONS = []


def ins(name, args, size, body):
    INSTRUCTIONS.append((name, args, size, body))


# Fixed one-byte and simple instructions.
for name, bts in [("Nop", "90"), ("Ret", "C3"), ("Lodsb", "AC"),
                  ("Stosb", "AA"), ("Stosl", "AB"), ("Movsb", "A4"),
                  ("Cld", "FC"), ("Cdq", "99"), ("Pushf", "9C"),
                  ("Popf", "9D")]:
    ins(name, [], len(bts.split()), bts)
ins("RepMovsb", [], 2, "F3 A4")
ins("RepeCmpsb", [], 2, "F3 A6")
ins("Int", ["b"], 2, "CD b")
ins("TestALI8", ["b"], 2, "A8 b")
ins("CmpALI8", ["b"], 2, "3C b")

# opcode+reg forms
ins("IncR", ["r"], 1, "(IncB r)")
ins("DecR", ["r"], 1, "(DecB r)")
ins("PushR", ["r"], 1, "(PushB r)")
ins("PopR", ["r"], 1, "(PopB r)")
ins("XchgEaxR", ["r"], 1, "(XchgAB r)")

# reg-reg ALU (op /r with mod=11; (Op dst src))
for name, op in [("MovRR", "89"), ("AddRR", "01"), ("SubRR", "29"),
                 ("CmpRR", "39"), ("TestRR", "85"), ("XorRR", "31"),
                 ("OrRR", "09"), ("AndRR", "21"), ("XchgRR", "87")]:
    ins(name, ["d", "s"], 2, f"{op} (RM11 s d)")

# imm8 ALU via 0x83 /ext, shifts via 0xC1 /ext, unary via 0xF7 /ext
for name, ext in [("AddI8", 0), ("OrI8", 1), ("AdcI8", 2), ("SbbI8", 3),
                  ("AndI8", 4), ("SubI8", 5), ("XorI8", 6), ("CmpI8", 7)]:
    ins(name, ["r", "b"], 3, f"83 (RMX {ext} r) b")
for name, ext in [("ShlI8", 4), ("ShrI8", 5), ("SarI8", 7)]:
    ins(name, ["r", "b"], 3, f"C1 (RMX {ext} r) b")
for name, ext in [("NotR", 2), ("NegR", 3), ("MulR", 4), ("DivR", 6),
                  ("IDivR", 7)]:
    ins(name, ["r"], 2, f"F7 (RMX {ext} r)")
ins("CallR", ["r"], 2, "FF (RMX 2 r)")
ins("JmpR", ["r"], 2, "FF (RMX 4 r)")

# imm32 ALU via 0x81 /ext; mov reg, imm32
for name, ext in [("AddI32", 0), ("AndI32", 4), ("SubI32", 5),
                  ("CmpI32", 7)]:
    ins(name, ["r", "x"], 6, f"81 (RMX {ext} r) (LEB x)")
ins("MovRI", ["r", "x"], 5, "(MovIB r) (LEB x)")
ins("MovRILabel", ["r", "l"], 5, "(MovIB r) (LEB (VAddr (Lookup l sym)))")
ins("MovRIConst", ["r", "l"], 5,
    "(MovIB r) (LEB (Add32 (VAddr (Lookup l sym)) (Small 1)))")

# memory via registers
ins("MovRM", ["r", "b"], 2, "8B (RM00 b r)")          # r = [b]
ins("MovMR", ["b", "r"], 2, "89 (RM00 b r)")          # [b] = r
ins("MovRMD", ["r", "b", "d"], 3, "8B (RM01 b r) d")  # r = [b+d8]
ins("MovMDR", ["b", "d", "r"], 3, "89 (RM01 b r) d")  # [b+d8] = r
ins("MovzxRMb", ["r", "b"], 3, "0F B6 (RM00 b r)")    # r = zx byte [b]
ins("MovbMR", ["b", "r"], 2, "88 (RM00 b r)")         # byte [b] = low8(r)
ins("LeaRMD", ["r", "b", "d"], 3, "8D (RM01 b r) d")  # r = b + disp8

# absolute-address memory (through labels)
ins("MovRMemL", ["r", "l"], 6, "8B (RM05 r) (LEB (VAddr (Lookup l sym)))")
ins("MovMemLR", ["l", "r"], 6, "89 (RM05 r) (LEB (VAddr (Lookup l sym)))")

# eax vs imm32
ins("CmpEaxI32", ["x"], 5, "3D (LEB x)")
ins("CmpEaxLabel", ["l"], 5, "3D (LEB (VAddr (Lookup l sym)))")

# data directives
ins("Db", ["b"], 1, "b")
ins("Dd", ["x"], 4, "(LEB x)")
ins("DLabel", ["l"], 4, "(LEB (VAddr (Lookup l sym)))")
ins("DConst", ["l"], 4, "(LEB (Add32 (VAddr (Lookup l sym)) (Small 1)))")
ins("DNil", [], 4, "01 00 00 00")

# short jumps (rel8)
SHORT_JUMPS = [("JmpS", "EB"), ("Jz", "74"), ("Jnz", "75"), ("Jb", "72"),
               ("Jae", "73"), ("Jbe", "76"), ("Ja", "77"), ("Js", "78"),
               ("Jns", "79"), ("Jl", "7C"), ("Jge", "7D"), ("Jle", "7E"),
               ("Jg", "7F")]
# long jumps (rel32)
LONG_JUMPS = [("Jmp32", "E9"), ("Call", "E8")]
LONG_CC = [("Jz32", "84"), ("Jnz32", "85"), ("Jb32", "82"), ("Jae32", "83"),
           ("Jbe32", "86"), ("Ja32", "87"), ("Jl32", "8C"), ("Jge32", "8D"),
           ("Jle32", "8E"), ("Jg32", "8F")]

section("Symbol table: keys are arbitrary terms, matched structurally.")
rule("(Lookup name (Bind other pc rest))", "(Lookup name rest)")
rule("(Lookup name (Bind name pc rest))", "pc")

section("Virtual addresses and ELF layout arithmetic.")
rule("(VBase)", "(X8 0 8 0 4 8 0 5 4)")
rule("(VAddr off)", "(Add32 (VBase) off)")
rule("(HdrSize)", "(X8 0 0 0 0 0 0 5 4)")
rule("(FileSz size)", "(Add32 (HdrSize) size)")

section("Instruction sizes.")
rule("(Size (Label name))", "(Small 0)")
for name, args, size, _ in INSTRUCTIONS:
    head = f"({name}{''.join(' ' + a for a in args)})"
    rule(f"(Size {head})", f"(Small {HEX[size]})")
for name, _ in SHORT_JUMPS:
    rule(f"(Size ({name} l))", "(Small 2)")
for name, _ in LONG_JUMPS:
    rule(f"(Size ({name} l))", "(Small 5)")
for name, _ in LONG_CC:
    rule(f"(Size ({name} l))", "(Small 6)")

section("Layout pass: label addresses as code offsets.")
rule("(Pass1 End pc sym)", "sym")
rule("(Pass1 (Ins instr rest) pc sym)",
     "(Pass1 rest (Add32 pc (Size instr)) sym)")
rule("(Pass1 (Ins (Label name) rest) pc sym)",
     "(Pass1 rest pc (Bind name pc sym))")
rule("(Pass1 (Ins (Align4) rest) pc sym)",
     "(Pass1 rest (Add32 pc (Pad4 pc)) sym)")
rule("(Pass1 (Ins (Align8) rest) pc sym)",
     "(Pass1 rest (Add32 pc (Pad8 pc)) sym)")

section("Code size pass.")
rule("(CodeSize End pc)", "pc")
rule("(CodeSize (Ins instr rest) pc)",
     "(CodeSize rest (Add32 pc (Size instr)))")
rule("(CodeSize (Ins (Align4) rest) pc)",
     "(CodeSize rest (Add32 pc (Pad4 pc)))")
rule("(CodeSize (Ins (Align8) rest) pc)",
     "(CodeSize rest (Add32 pc (Pad8 pc)))")

section("Emission pass.")
rule("(Pass2 End pc sym)", "(Bytes)")
rule("(Pass2 (Ins (Label name) rest) pc sym)", "(Pass2 rest pc sym)")
rule("(Pass2 (Ins (Align4) rest) pc sym)",
     "(Bytes (PadOut (Pad4 pc)) (Pass2 rest (Add32 pc (Pad4 pc)) sym))")
rule("(Pass2 (Ins (Align8) rest) pc sym)",
     "(Bytes (PadOut (Pad8 pc)) (Pass2 rest (Add32 pc (Pad8 pc)) sym))")
for name, args, size, body in INSTRUCTIONS:
    head = f"({name}{''.join(' ' + a for a in args)})"
    rule(f"(Pass2 (Ins {head} rest) pc sym)",
         f"(Bytes {body} (Pass2 rest (Add32 pc (Small {HEX[size]})) sym))")
for name, op in SHORT_JUMPS:
    rule(f"(Pass2 (Ins ({name} l) rest) pc sym)",
         f"(Bytes {op} (Rel8 (Sub32 (Lookup l sym) (Add32 pc (Small 2))))"
         f" (Pass2 rest (Add32 pc (Small 2)) sym))")
for name, op in LONG_JUMPS:
    rule(f"(Pass2 (Ins ({name} l) rest) pc sym)",
         f"(Bytes {op} (LEB (Sub32 (Lookup l sym) (Add32 pc (Small 5))))"
         f" (Pass2 rest (Add32 pc (Small 5)) sym))")
for name, op in LONG_CC:
    rule(f"(Pass2 (Ins ({name} l) rest) pc sym)",
         f"(Bytes 0F {op} (LEB (Sub32 (Lookup l sym) (Add32 pc (Small 6))))"
         f" (Pass2 rest (Add32 pc (Small 6)) sym))")

section("ELF emission: one RWE LOAD segment, optional extra bss memory.")
rule("(ElfHeader entryoff codesize bss)",
     "(Bytes 7F 45 4C 46 01 01 01 00 00 00 00 00 00 00 00 00"
     " 02 00 03 00 01 00 00 00"
     " (LEB (VAddr entryoff))"
     " 34 00 00 00 00 00 00 00 00 00 00 00"
     " 34 00 20 00 01 00 00 00 00 00 00 00"
     " 01 00 00 00 00 00 00 00"
     " 00 80 04 08 00 80 04 08"
     " (LEB (FileSz codesize))"
     " (LEB (Add32 (FileSz codesize) bss))"
     " 07 00 00 00 00 10 00 00)")

section("Top level.")
rule("(Assemble (Program entry code))",
     "(Assemble (Program entry (Small 0) code))")
rule("(Assemble (Program entry bss code))",
     "(Asm2 entry bss code (Pass1 code (Small 0) Empty)"
     " (CodeSize code (Small 0)))")
rule("(Asm2 entry bss code sym size)",
     "(Bytes (ElfHeader (Lookup entry sym) size bss)"
     " (Pass2 code (Small 0) sym))")


def main():
    print("; General Qfitzah-hosted i386 assembler (Stage 1).")
    print("; GENERATED by tools/generate_qfasm.py -- do not edit by hand.")
    print("; Numbers are little-endian nybble lists (N d0 ... d7); see the")
    print("; generator for the architecture notes.")
    for line in out:
        if line is None:
            continue
        print(line)


if __name__ == "__main__":
    main()
