#!/usr/bin/env python3
"""Emit bootstrap/rsc-runtime.qf1, the fixed assembly runtime for Stage 4.

sc1.scm (the Scheme-to-qfasm compiler) emits programs whose fixed runtime
(heap init, cons, object allocation, buffered IO, the printer, symbol
interning and every primitive) is provided by this file as two rewrite-rule
macros, expanded by the seed exactly like build_scheme0.py's (Z n) blocks:

    (RuntimeCode rest)  -> (Ins <fixed code...> rest)
    (RuntimeData rest)  -> (Ins <fixed data...> rest)

The compiler ends its instruction chain with (RuntimeCode (RuntimeData End)).
This file also defines two extra assembler directives it needs, DObj and
MovRIObj (like DConst/MovRIConst but +2, for tagging object pointers).

Value representation is identical to scheme0 (see tools/build_scheme0.py).

Calling convention used by compiled code (sc1):
  * EBP holds the current environment (a heap list of frames).
  * A callable is an object (subtype 2): payload pair = (code-addr . env).
  * Apply: arglist in EAX, captured env in EDI, then CALL/JMP the code addr.
  * Primitive code consumes the arglist in EAX (scheme0 convention) and RETs.
  * User-lambda code (emitted by sc1) builds a frame from EAX, sets EBP, runs.

Run: python3 tools/generate_sc1_runtime.py > bootstrap/rsc-runtime.qf1
"""


def x8(v):
    v &= 0xFFFFFFFF
    return "(X8 " + " ".join(f"{(v >> (28 - 4 * i)) & 15:X}"
                             for i in range(8)) + ")"


def imm(v):
    if 0 <= v <= 15:
        return f"(Small {v:X})"
    return x8(v)


NIL = 0x03
TRUE = 0x13
FALSE = 0x23
EOFV = 0x33
UNSPEC = 0x43
MINUS1 = 0xFFFFFFFF

# Primitives: (scheme name, code label). eq?/eqv? share code.
PRIMS = [("cons", "PrCons"), ("car", "PrCar"), ("cdr", "PrCdr"),
         ("set-car!", "PrSetCar"), ("set-cdr!", "PrSetCdr"),
         ("pair?", "PrPairQ"), ("null?", "PrNullQ"),
         ("eq?", "PrEqQ"), ("eqv?", "PrEqQ"),
         ("symbol?", "PrSymQ"), ("number?", "PrNumQ"),
         ("string?", "PrStrQ"), ("char?", "PrCharQ"),
         ("procedure?", "PrProcQ"), ("boolean?", "PrBoolQ"),
         ("not", "PrNot"),
         ("+", "PrAdd"), ("-", "PrSub"), ("*", "PrMul"),
         ("quotient", "PrQuot"), ("remainder", "PrRem"),
         ("=", "PrNumEq"), ("<", "PrLt"), (">", "PrGt"),
         ("<=", "PrLe"), (">=", "PrGe"),
         ("display", "PrDisplay"), ("write", "PrWrite"),
         ("newline", "PrNewline"),
         ("read-char", "PrReadChar"), ("peek-char", "PrPeekChar"),
         ("eof-object?", "PrEofQ"),
         ("char->integer", "PrCharInt"), ("integer->char", "PrIntChar"),
         ("string-length", "PrStrLen"), ("string-ref", "PrStrRef"),
         ("string->symbol", "PrStrSym"), ("symbol->string", "PrSymStr"),
         ("list->string", "PrListStr"),
         ("make-string", "PrMakeStr"), ("string-set!", "PrStrSet"),
         ("apply", "PrApply"),
         ("make-vector", "PrMakeVec"), ("vector", "PrVector"),
         ("vector-ref", "PrVecRef"), ("vector-set!", "PrVecSet"),
         ("vector-length", "PrVecLen"), ("vector?", "PrVecQ"),
         ("vector->list", "PrVecList"), ("list->vector", "PrListVec"),
         ("error", "PrError"), ("exit", "PrExit")]

# --- P1 substrate extensions (added in parts, see below) -------------------
# Part A: 32-bit word ("w32") values (object subtype 5) + raw vector words.
PRIMS += [
    ("w32-from-fixnum", "PrW32FromFix"), ("w32->fixnum", "PrW32ToFix"),
    ("w32?", "PrW32Q"),
    ("w32-add", "PrW32Add"), ("w32-sub", "PrW32Sub"), ("w32-mul", "PrW32Mul"),
    ("w32-quot", "PrW32Quot"), ("w32-rem", "PrW32Rem"),
    ("w32-uquot", "PrW32UQuot"), ("w32-urem", "PrW32URem"),
    ("w32-and", "PrW32And"), ("w32-or", "PrW32Or"),
    ("w32-xor", "PrW32Xor"), ("w32-not", "PrW32Not"),
    ("w32-shl", "PrW32Shl"), ("w32-shr", "PrW32Shr"), ("w32-sar", "PrW32Sar"),
    ("w32-eq?", "PrW32EqQ"), ("w32-lt?", "PrW32LtQ"), ("w32-ult?", "PrW32UltQ"),
    ("vec-raw-ref", "PrVecRawRef"), ("vec-raw-set!", "PrVecRawSet")]

C = []   # code instructions
D = []   # data directives
CUR = C


def I(text):
    CUR.append(text)


def L(name):
    CUR.append(f"(Label {name})")


def PL(name):
    I("(Align8)")
    L(name)


def MOVRI(r, v):
    I(f"(MovRI {r} {imm(v)})")


def CMPEAX(v):
    I(f"(CmpEaxI32 {imm(v)})")


def call(t):
    I(f"(Call {t})")


def gv(name):
    return f"(GV {name})"


# ===========================================================================
# CODE
# ===========================================================================
CUR = C

# --- HeapInit: set up the bump allocators past CodeEnd -----------------------
L("HeapInit")
I("(MovRILabel EAX CodeEnd)")
I("(AddI8 EAX 07)")
I("(AndI8 EAX F8)")
I("(MovMemLR GCellFree EAX)")
I(f"(AddI32 EAX {x8(0x0C000000)})")   # 192 MiB of cells
I("(MovMemLR GByteFree EAX)")
I(f"(AddI32 EAX {x8(0x02000000)})")   # 32 MiB of bytes
I("(MovMemLR GReadBuf EAX)")
I("(MovMemLR GInPtr EAX)")
I("(MovMemLR GInEnd EAX)")
I(f"(AddI32 EAX {x8(0x01000000)})")   # 16 MiB read buffer
I("(MovMemLR GTokBuf EAX)")
I("(Ret)")

# --- InitPrims: build a closure object for every primitive -------------------
L("InitPrims")
for name, code in PRIMS:
    I(f"(MovRILabel EAX {code})")
    MOVRI("ECX", NIL)                 # env = nil
    call("Cons")                      # payload pair (code . nil)
    I("(OrI8 EAX 02)")                # payload | closure subtype
    MOVRI("ECX", 1)                   # meta cdr: fixnum 0
    call("Cons")                      # object cell
    I("(OrI8 EAX 02)")                # object pointer
    I(f"(MovMemLR {gv(name)} EAX)")
I("(Ret)")

# --- Cons(EAX, ECX) -> pair; preserves ECX EDX -------------------------------
L("Cons")
I("(PushR EDX)")
I("(MovRMemL EDX GCellFree)")
I("(MovMR EDX EAX)")
I("(MovMDR EDX 04 ECX)")
I("(MovRR EAX EDX)")
I("(AddI8 EDX 08)")
I("(MovMemLR GCellFree EDX)")
I("(PopR EDX)")
I("(Ret)")

# --- AllocObj(EAX=src bytes, ECX=len, EDX=subtag) -> tagged object -----------
L("AllocObj")
I("(PushR EDX)")
I("(MovRMemL EDI GByteFree)")
I("(PushR EDI)")
I("(MovRR ESI EAX)")
I("(PushR ECX)")
I("(RepMovsb)")
I("(PopR ECX)")
I("(MovRR EAX EDI)")
I("(AddI8 EAX 07)")
I("(AndI8 EAX F8)")
I("(MovMemLR GByteFree EAX)")
I("(PopR EAX)")
I("(PopR EDX)")
I("(OrRR EAX EDX)")
I("(PushR EAX)")
I("(MovRR EAX ECX)")
I("(ShlI8 EAX 02)")
I("(OrI8 EAX 01)")
I("(MovRR ECX EAX)")
I("(PopR EAX)")
call("Cons")
I("(OrI8 EAX 02)")
I("(Ret)")

# --- Buffered input ----------------------------------------------------------
L("ReadCh")
I("(MovRMemL EAX GPeek)")
CMPEAX(MINUS1)
I("(Jz (RC 1))")
I("(PushR ECX)")
MOVRI("ECX", MINUS1)
I("(MovMemLR GPeek ECX)")
I("(PopR ECX)")
I("(Ret)")
L("(RC 1)")
I("(PushR ECX)")
I("(MovRMemL EAX GInPtr)")
I("(MovRMemL ECX GInEnd)")
I("(CmpRR EAX ECX)")
I("(Jnz (RC 3))")
I("(PushR EBX)")
I("(PushR EDX)")
MOVRI("EAX", 3)
I("(XorRR EBX EBX)")
I("(MovRMemL ECX GReadBuf)")
MOVRI("EDX", 0x01000000)
I("(Int 80)")
I("(TestRR EAX EAX)")
I("(Jg (RC 2))")
I("(PopR EDX)")
I("(PopR EBX)")
I("(PopR ECX)")
MOVRI("EAX", MINUS1)
I("(Ret)")
L("(RC 2)")
I("(MovRMemL ECX GReadBuf)")
I("(MovMemLR GInPtr ECX)")
I("(AddRR ECX EAX)")
I("(MovMemLR GInEnd ECX)")
I("(PopR EDX)")
I("(PopR EBX)")
I("(MovRMemL EAX GInPtr)")
L("(RC 3)")
I("(MovRR ECX EAX)")
I("(MovzxRMb EAX ECX)")
I("(IncR ECX)")
I("(MovMemLR GInPtr ECX)")
I("(PopR ECX)")
I("(Ret)")

L("PeekCh")
call("ReadCh")
I("(MovMemLR GPeek EAX)")
I("(Ret)")

# --- Output ------------------------------------------------------------------
L("Emit")
I("(PushR EBX)")
I("(PushR ECX)")
I("(PushR EDX)")
I("(MovRILabel ECX WriteChBuf)")
I("(MovbMR ECX EAX)")
MOVRI("EAX", 4)
MOVRI("EBX", 1)
MOVRI("EDX", 1)
I("(Int 80)")
I("(PopR EDX)")
I("(PopR ECX)")
I("(PopR EBX)")
I("(Ret)")

L("PrintRaw")
MOVRI("EAX", 4)
MOVRI("EBX", 1)
I("(Int 80)")
I("(Ret)")

L("ErrApply")
MOVRI("EAX", 0x21)
call("Emit")
MOVRI("EAX", 0x0A)
call("Emit")
MOVRI("EAX", 1)
MOVRI("EBX", 1)
I("(Int 80)")

# --- Intern(EAX=bytes, ECX=len) -> symbol ------------------------------------
L("Intern")
I("(MovRMemL EDX GObList)")
L("(IN 1)")
I("(TestRI8 EDX 03)")
I("(Jz (IN 2))")
I("(XorRR EDX EDX)")
call("AllocObj")
I("(PushR EAX)")
I("(MovRMemL ECX GObList)")
call("Cons")
I("(MovMemLR GObList EAX)")
I("(PopR EAX)")
I("(Ret)")
L("(IN 2)")
I("(MovRM EBX EDX)")
I("(MovRR EDI EBX)")
I("(SubI8 EDI 02)")
I("(MovRMD ESI EDI 04)")
I("(SarI8 ESI 02)")
I("(CmpRR ESI ECX)")
I("(Jnz (IN 3))")
I("(MovRM ESI EDI)")
I("(MovRR EDI EAX)")
I("(PushR ECX)")
I("(RepeCmpsb)")
I("(PopR ECX)")
I("(Jnz (IN 3))")
I("(MovRR EAX EBX)")
I("(Ret)")
L("(IN 3)")
I("(MovRMD EDX EDX 04)")
I("(JmpS (IN 1))")

# ===========================================================================
# Primitives (arglist in EAX, result in EAX, RET)
# ===========================================================================
def ret_bool(prefix):
    L(f"({prefix} T)")
    MOVRI("EAX", TRUE)
    I("(Ret)")
    L(f"({prefix} F)")
    MOVRI("EAX", FALSE)
    I("(Ret)")


PL("PrCons")
I("(MovRMD ECX EAX 04)")
I("(MovRM ECX ECX)")
I("(MovRM EAX EAX)")
I("(Jmp32 Cons)")

PL("PrCar")
I("(MovRM EAX EAX)")
I("(TestRI8 EAX 03)")
I("(Jz (CAR 1))")
I("(Jmp32 ErrApply)")
L("(CAR 1)")
I("(MovRM EAX EAX)")
I("(Ret)")

PL("PrCdr")
I("(MovRM EAX EAX)")
I("(TestRI8 EAX 03)")
I("(Jz (CDR 1))")
I("(Jmp32 ErrApply)")
L("(CDR 1)")
I("(MovRMD EAX EAX 04)")
I("(Ret)")

PL("PrSetCar")
I("(MovRM ECX EAX)")
I("(MovRMD EAX EAX 04)")
I("(MovRM EAX EAX)")
I("(MovMR ECX EAX)")
MOVRI("EAX", UNSPEC)
I("(Ret)")

PL("PrSetCdr")
I("(MovRM ECX EAX)")
I("(MovRMD EAX EAX 04)")
I("(MovRM EAX EAX)")
I("(MovMDR ECX 04 EAX)")
MOVRI("EAX", UNSPEC)
I("(Ret)")

PL("PrPairQ")
I("(MovRM EAX EAX)")
I("(TestRI8 EAX 03)")
I("(Jz (PQ T))")
I("(JmpS (PQ F))")
ret_bool("PQ")

PL("PrNullQ")
I("(MovRM EAX EAX)")
CMPEAX(NIL)
I("(Jz (NQ T))")
I("(JmpS (NQ F))")
ret_bool("NQ")

PL("PrEqQ")
I("(MovRM ECX EAX)")
I("(MovRMD EAX EAX 04)")
I("(MovRM EAX EAX)")
I("(CmpRR EAX ECX)")
I("(Jz (EQ T))")
I("(JmpS (EQ F))")
ret_bool("EQ")

PL("PrSymQ")
I("(MovRM EAX EAX)")
I("(MovRR ECX EAX)")
I("(AndI8 ECX 03)")
I("(CmpI8 ECX 02)")
I("(Jnz (SYQ F))")
I("(SubI8 EAX 02)")
I("(MovRM EAX EAX)")
I("(TestRI8 EAX 07)")
I("(Jz (SYQ T))")
I("(JmpS (SYQ F))")
ret_bool("SYQ")

PL("PrNumQ")
I("(MovRM EAX EAX)")
I("(TestRI8 EAX 01)")
I("(Jz (NUQ F))")
I("(TestRI8 EAX 02)")
I("(Jz (NUQ T))")
I("(JmpS (NUQ F))")
ret_bool("NUQ")

PL("PrStrQ")
I("(MovRM EAX EAX)")
I("(MovRR ECX EAX)")
I("(AndI8 ECX 03)")
I("(CmpI8 ECX 02)")
I("(Jnz (STQ F))")
I("(SubI8 EAX 02)")
I("(MovRM EAX EAX)")
I("(AndI8 EAX 07)")
I("(CmpI8 EAX 01)")
I("(Jz (STQ T))")
I("(JmpS (STQ F))")
ret_bool("STQ")

PL("PrCharQ")
I("(MovRM EAX EAX)")
I(f"(AndI32 EAX {x8(0xFF)})")
I("(CmpI8 EAX 53)")
I("(Jz (CHQ T))")
I("(JmpS (CHQ F))")
ret_bool("CHQ")

PL("PrProcQ")
I("(MovRM EAX EAX)")
I("(MovRR ECX EAX)")
I("(AndI8 ECX 03)")
I("(CmpI8 ECX 02)")
I("(Jnz (PCQ F))")
I("(SubI8 EAX 02)")
I("(MovRM EAX EAX)")
I("(AndI8 EAX 07)")
I("(CmpI8 EAX 02)")
I("(Jz (PCQ T))")
I("(CmpI8 EAX 03)")
I("(Jz (PCQ T))")
I("(JmpS (PCQ F))")
ret_bool("PCQ")

PL("PrBoolQ")
I("(MovRM EAX EAX)")
CMPEAX(TRUE)
I("(Jz (BQ T))")
CMPEAX(FALSE)
I("(Jz (BQ T))")
I("(JmpS (BQ F))")
ret_bool("BQ")

PL("PrNot")
I("(MovRM EAX EAX)")
CMPEAX(FALSE)
I("(Jz (NO T))")
I("(JmpS (NO F))")
ret_bool("NO")

PL("PrAdd")
MOVRI("ECX", 1)
L("(AD 1)")
I("(TestRI8 EAX 03)")
I("(Jnz (AD 2))")
I("(MovRM EDX EAX)")
I("(AddRR ECX EDX)")
I("(DecR ECX)")
I("(MovRMD EAX EAX 04)")
I("(JmpS (AD 1))")
L("(AD 2)")
I("(MovRR EAX ECX)")
I("(Ret)")

PL("PrSub")
I("(MovRM ECX EAX)")
I("(MovRMD EAX EAX 04)")
I("(TestRI8 EAX 03)")
I("(Jz (SB 1))")
MOVRI("EAX", 2)
I("(SubRR EAX ECX)")
I("(Ret)")
L("(SB 1)")
I("(MovRM EDX EAX)")
I("(SubRR ECX EDX)")
I("(IncR ECX)")
I("(MovRMD EAX EAX 04)")
I("(TestRI8 EAX 03)")
I("(Jz (SB 1))")
I("(MovRR EAX ECX)")
I("(Ret)")

PL("PrMul")
MOVRI("ECX", 1)
L("(MU 1)")
I("(TestRI8 EAX 03)")
I("(Jnz (MU 2))")
I("(MovRM EDX EAX)")
I("(SarI8 EDX 02)")
I("(IMulRR ECX EDX)")
I("(MovRMD EAX EAX 04)")
I("(JmpS (MU 1))")
L("(MU 2)")
I("(MovRR EAX ECX)")
I("(ShlI8 EAX 02)")
I("(OrI8 EAX 01)")
I("(Ret)")

PL("PrQuot")
I("(MovRM ECX EAX)")
I("(MovRMD EAX EAX 04)")
I("(MovRM EBX EAX)")
I("(MovRR EAX ECX)")
I("(SarI8 EAX 02)")
I("(SarI8 EBX 02)")
I("(Cdq)")
I("(IDivR EBX)")
I("(ShlI8 EAX 02)")
I("(OrI8 EAX 01)")
I("(Ret)")

PL("PrRem")
I("(MovRM ECX EAX)")
I("(MovRMD EAX EAX 04)")
I("(MovRM EBX EAX)")
I("(MovRR EAX ECX)")
I("(SarI8 EAX 02)")
I("(SarI8 EBX 02)")
I("(Cdq)")
I("(IDivR EBX)")
I("(MovRR EAX EDX)")
I("(ShlI8 EAX 02)")
I("(OrI8 EAX 01)")
I("(Ret)")


def cmp_prim(label, prefix, jcc):
    PL(label)
    I("(MovRM ECX EAX)")
    I("(MovRMD EAX EAX 04)")
    I("(MovRM EAX EAX)")
    I("(CmpRR ECX EAX)")
    I(f"({jcc} ({prefix} T))")
    I(f"(JmpS ({prefix} F))")
    ret_bool(prefix)


cmp_prim("PrNumEq", "NE", "Jz")
cmp_prim("PrLt", "LTP", "Jl")
cmp_prim("PrGt", "GTP", "Jg")
cmp_prim("PrLe", "LEP", "Jle")
cmp_prim("PrGe", "GEP", "Jge")

PL("PrDisplay")
I("(MovRM EAX EAX)")
I("(MovRR ECX EAX)")
I("(AndI8 ECX 03)")
I("(CmpI8 ECX 02)")
I("(Jnz (DS 2))")
I("(MovRR EDX EAX)")
I("(SubI8 EDX 02)")
I("(MovRM ECX EDX)")
I("(MovRR EBX ECX)")
I("(AndI8 EBX 07)")
I("(CmpI8 EBX 01)")
I("(Jnz (DS 3))")
I("(AndI8 ECX F8)")
I("(MovRMD EDX EDX 04)")
I("(SarI8 EDX 02)")
call("PrintRaw")
MOVRI("EAX", UNSPEC)
I("(Ret)")
L("(DS 2)")
I("(CmpI8 ECX 03)")
I("(Jnz (DS 3))")
I("(MovRR EDX EAX)")
I(f"(AndI32 EDX {x8(0xFF)})")
I("(CmpI8 EDX 53)")
I("(Jnz (DS 3))")
I("(ShrI8 EAX 08)")
call("Emit")
MOVRI("EAX", UNSPEC)
I("(Ret)")
L("(DS 3)")
call("Print")
MOVRI("EAX", UNSPEC)
I("(Ret)")

PL("PrWrite")
I("(MovRM EAX EAX)")
call("Print")
MOVRI("EAX", UNSPEC)
I("(Ret)")

PL("PrNewline")
MOVRI("EAX", 0x0A)
call("Emit")
MOVRI("EAX", UNSPEC)
I("(Ret)")

PL("PrReadChar")
call("ReadCh")
CMPEAX(MINUS1)
I("(Jz (RDC 1))")
I("(ShlI8 EAX 08)")
I("(OrI8 EAX 53)")
I("(Ret)")
L("(RDC 1)")
MOVRI("EAX", EOFV)
I("(Ret)")

PL("PrPeekChar")
call("PeekCh")
CMPEAX(MINUS1)
I("(Jz (PKC 1))")
I("(ShlI8 EAX 08)")
I("(OrI8 EAX 53)")
I("(Ret)")
L("(PKC 1)")
MOVRI("EAX", EOFV)
I("(Ret)")

PL("PrEofQ")
I("(MovRM EAX EAX)")
CMPEAX(EOFV)
I("(Jz (EFQ T))")
I("(JmpS (EFQ F))")
ret_bool("EFQ")

PL("PrCharInt")
I("(MovRM EAX EAX)")
I("(ShrI8 EAX 08)")
I("(ShlI8 EAX 02)")
I("(OrI8 EAX 01)")
I("(Ret)")

PL("PrIntChar")
I("(MovRM EAX EAX)")
I("(SarI8 EAX 02)")
I("(ShlI8 EAX 08)")
I("(OrI8 EAX 53)")
I("(Ret)")

PL("PrStrLen")
I("(MovRM EAX EAX)")
I("(SubI8 EAX 02)")
I("(MovRMD EAX EAX 04)")
I("(Ret)")

PL("PrStrRef")
I("(MovRM ECX EAX)")
I("(MovRMD EAX EAX 04)")
I("(MovRM EDX EAX)")
I("(SubI8 ECX 02)")
I("(MovRM EBX ECX)")
I("(AndI8 EBX F8)")
I("(SarI8 EDX 02)")
I("(AddRR EBX EDX)")
I("(MovzxRMb EAX EBX)")
I("(ShlI8 EAX 08)")
I("(OrI8 EAX 53)")
I("(Ret)")

PL("PrStrSym")
I("(MovRM EAX EAX)")
I("(SubI8 EAX 02)")
I("(MovRR EDX EAX)")
I("(MovRM EAX EDX)")
I("(AndI8 EAX F8)")
I("(MovRMD ECX EDX 04)")
I("(SarI8 ECX 02)")
I("(Jmp32 Intern)")

PL("PrSymStr")
I("(MovRM EAX EAX)")
I("(SubI8 EAX 02)")
I("(MovRM EDX EAX)")
I("(OrI8 EDX 01)")
I("(MovRMD ECX EAX 04)")
I("(MovRR EAX EDX)")
call("Cons")
I("(OrI8 EAX 02)")
I("(Ret)")

PL("PrListStr")
I("(MovRM EDX EAX)")
I("(MovRMemL EDI GTokBuf)")
L("(LS 1)")
I("(TestRI8 EDX 03)")
I("(Jnz (LS 2))")
I("(MovRM EAX EDX)")
I("(ShrI8 EAX 08)")
I("(MovbMR EDI EAX)")
I("(IncR EDI)")
I("(MovRMD EDX EDX 04)")
I("(JmpS (LS 1))")
L("(LS 2)")
I("(MovRMemL EAX GTokBuf)")
I("(MovRR ECX EDI)")
I("(SubRR ECX EAX)")
MOVRI("EDX", 1)
I("(Jmp32 AllocObj)")

# --- make-string / string-set! (mutable byte buffers) -----------------------
PL("PrMakeStr")
I("(MovRM ECX EAX)")               # ECX = k fixnum
I("(SarI8 ECX 02)")                # k int
I("(MovRMD EDX EAX 04)")           # EDX = cdr (fill?)
I("(TestRI8 EDX 03)")
I("(Jz (MS 0))")
MOVRI("EBX", 0x20)                 # default fill = space
I("(JmpS (MS 1))")
L("(MS 0)")
I("(MovRM EBX EDX)")               # EBX = fill char immediate
I("(ShrI8 EBX 08)")                # byte
L("(MS 1)")
I("(MovRMemL EDI GByteFree)")
I("(PushR EDI)")
I("(PushR ECX)")
L("(MS 2)")
I("(TestRR ECX ECX)")
I("(Jz (MS 3))")
I("(MovbMR EDI EBX)")
I("(IncR EDI)")
I("(DecR ECX)")
I("(JmpS (MS 2))")
L("(MS 3)")
I("(MovRR EAX EDI)")
I("(AddI8 EAX 07)")
I("(AndI8 EAX F8)")
I("(MovMemLR GByteFree EAX)")
I("(PopR ECX)")
I("(PopR EAX)")
I("(OrI8 EAX 01)")                 # subtype 1 = string
I("(PushR EAX)")
I("(MovRR EAX ECX)")
I("(ShlI8 EAX 02)")
I("(OrI8 EAX 01)")
I("(MovRR ECX EAX)")
I("(PopR EAX)")
call("Cons")
I("(OrI8 EAX 02)")
I("(Ret)")

PL("PrStrSet")
I("(MovRM ECX EAX)")               # ECX = s obj
I("(MovRMD EAX EAX 04)")           # EAX = (i ch)
I("(MovRM EDX EAX)")               # EDX = i fixnum
I("(SarI8 EDX 02)")                # i (byte offset)
I("(MovRMD EAX EAX 04)")           # EAX = (ch)
I("(MovRM EAX EAX)")               # EAX = ch immediate
I("(ShrI8 EAX 08)")                # byte in AL
I("(SubI8 ECX 02)")
I("(MovRM ECX ECX)")               # car = buffer|1
I("(AndI8 ECX F8)")                # buffer
I("(AddRR ECX EDX)")               # buffer + i
I("(MovbMR ECX EAX)")              # [buffer+i] = AL
MOVRI("EAX", UNSPEC)
I("(Ret)")

# --- apply: (apply f a b ... lst). Splices the fixed args onto lst and
# --- tail-jumps into f, so tail apply does not grow the machine stack. -------
L("AppendArgs")                    # EAX = (a1 ... lastlist), >=1 elt -> spliced
I("(MovRMD ECX EAX 04)")           # ECX = cdr
I("(TestRI8 ECX 03)")
I("(Jnz (APA 1))")                 # cdr not a pair -> car is the final list
I("(PushR EAX)")
I("(MovRR EAX ECX)")
call("AppendArgs")                 # EAX = spliced rest
I("(PopR ECX)")                    # ECX = saved node
I("(MovRR EDX EAX)")               # EDX = spliced rest
I("(MovRM EAX ECX)")               # EAX = car
I("(MovRR ECX EDX)")               # ECX = cdr = spliced rest
I("(Jmp32 Cons)")
L("(APA 1)")
I("(MovRM EAX EAX)")               # EAX = car = final list
I("(Ret)")

PL("PrApply")
I("(MovRM EBX EAX)")               # EBX = f
I("(MovRMD EAX EAX 04)")           # EAX = (a1 ... lastlist)
I("(TestRI8 EAX 03)")
I("(Jz (APL 1))")
MOVRI("EAX", NIL)                  # (apply f) -> empty arglist
I("(JmpS (APL 2))")
L("(APL 1)")
call("AppendArgs")
L("(APL 2)")
I("(MovRR ESI EBX)")               # invoke closure EBX with arglist EAX
I("(SubI8 ESI 02)")
I("(MovRM ESI ESI)")
I("(AndI8 ESI F8)")
I("(MovRMD EDI ESI 04)")           # EDI = captured env
I("(MovRM ESI ESI)")               # ESI = code
I("(JmpR ESI)")                    # tail-jump

# --- vectors (object subtype 4: car = eltbuf|4, cdr = length fixnum) --------
PL("PrMakeVec")
I("(MovRM ECX EAX)")               # ECX = k fixnum
I("(SarI8 ECX 02)")                # k int
I("(MovRMD EDX EAX 04)")           # EDX = cdr (fill?)
I("(TestRI8 EDX 03)")
I("(Jz (MV 0))")
MOVRI("EBX", FALSE)                # default fill = #f
I("(JmpS (MV 1))")
L("(MV 0)")
I("(MovRM EBX EDX)")               # EBX = fill value
L("(MV 1)")
I("(MovRMemL EDI GByteFree)")
I("(PushR EDI)")
I("(PushR ECX)")
L("(MV 2)")
I("(TestRR ECX ECX)")
I("(Jz (MV 3))")
I("(MovMR EDI EBX)")               # store fill word
I("(AddI8 EDI 04)")
I("(DecR ECX)")
I("(JmpS (MV 2))")
L("(MV 3)")
I("(MovRR EAX EDI)")
I("(AddI8 EAX 07)")
I("(AndI8 EAX F8)")
I("(MovMemLR GByteFree EAX)")
I("(PopR ECX)")
I("(PopR EAX)")
I("(OrI8 EAX 04)")                 # subtype 4 = vector
I("(PushR EAX)")
I("(MovRR EAX ECX)")
I("(ShlI8 EAX 02)")
I("(OrI8 EAX 01)")
I("(MovRR ECX EAX)")
I("(PopR EAX)")
call("Cons")
I("(OrI8 EAX 02)")
I("(Ret)")

PL("PrVector")
I("(MovRR EDX EAX)")               # element list = arglist
I("(Jmp32 VecFromList)")

PL("PrListVec")
I("(MovRM EDX EAX)")               # EDX = the list argument
I("(Jmp32 VecFromList)")

L("VecFromList")                   # EDX = list -> vector in EAX
I("(XorRR ECX ECX)")
I("(MovRR EBX EDX)")
L("(LV 1)")
I("(TestRI8 EBX 03)")
I("(Jnz (LV 2))")
I("(IncR ECX)")
I("(MovRMD EBX EBX 04)")
I("(JmpS (LV 1))")
L("(LV 2)")
I("(MovRMemL EDI GByteFree)")
I("(PushR EDI)")
I("(PushR ECX)")
I("(MovRR EBX EDX)")
L("(LV 3)")
I("(TestRI8 EBX 03)")
I("(Jnz (LV 4))")
I("(MovRM EAX EBX)")
I("(MovMR EDI EAX)")
I("(AddI8 EDI 04)")
I("(MovRMD EBX EBX 04)")
I("(JmpS (LV 3))")
L("(LV 4)")
I("(MovRR EAX EDI)")
I("(AddI8 EAX 07)")
I("(AndI8 EAX F8)")
I("(MovMemLR GByteFree EAX)")
I("(PopR ECX)")
I("(PopR EAX)")
I("(OrI8 EAX 04)")
I("(PushR EAX)")
I("(MovRR EAX ECX)")
I("(ShlI8 EAX 02)")
I("(OrI8 EAX 01)")
I("(MovRR ECX EAX)")
I("(PopR EAX)")
call("Cons")
I("(OrI8 EAX 02)")
I("(Ret)")

PL("PrVecRef")
I("(MovRM ECX EAX)")               # ECX = v obj
I("(MovRMD EAX EAX 04)")           # EAX = (i)
I("(MovRM EAX EAX)")               # EAX = i fixnum
I("(AndI8 EAX FC)")                # i*4 (clear tag)
I("(SubI8 ECX 02)")
I("(MovRM ECX ECX)")               # car = buffer|4
I("(AndI8 ECX F8)")                # buffer
I("(AddRR ECX EAX)")
I("(MovRM EAX ECX)")               # element
I("(Ret)")

PL("PrVecSet")
I("(MovRM ECX EAX)")               # ECX = v obj
I("(MovRMD EAX EAX 04)")           # EAX = (i x)
I("(MovRM EDX EAX)")               # EDX = i fixnum
I("(AndI8 EDX FC)")                # i*4
I("(MovRMD EAX EAX 04)")           # EAX = (x)
I("(MovRM EAX EAX)")               # EAX = x
I("(SubI8 ECX 02)")
I("(MovRM ECX ECX)")               # car
I("(AndI8 ECX F8)")                # buffer
I("(AddRR ECX EDX)")
I("(MovMR ECX EAX)")               # buffer[i] = x
MOVRI("EAX", UNSPEC)
I("(Ret)")

PL("PrVecLen")
I("(MovRM EAX EAX)")
I("(SubI8 EAX 02)")
I("(MovRMD EAX EAX 04)")           # cdr = length fixnum
I("(Ret)")

PL("PrVecQ")
I("(MovRM EAX EAX)")
I("(MovRR ECX EAX)")
I("(AndI8 ECX 03)")
I("(CmpI8 ECX 02)")
I("(Jnz (VQ F))")
I("(SubI8 EAX 02)")
I("(MovRM EAX EAX)")
I("(AndI8 EAX 07)")
I("(CmpI8 EAX 04)")
I("(Jz (VQ T))")
I("(JmpS (VQ F))")
ret_bool("VQ")

PL("PrVecList")
I("(MovRM EAX EAX)")               # EAX = v obj
I("(SubI8 EAX 02)")
I("(MovRMD EDX EAX 04)")           # EDX = length fixnum
I("(SarI8 EDX 02)")                # count int
I("(MovRM EAX EAX)")               # car = buffer|4
I("(AndI8 EAX F8)")                # buffer
I("(MovRR EBX EAX)")               # EBX = base
MOVRI("EAX", NIL)                  # acc = nil
L("(VL2 1)")
I("(TestRR EDX EDX)")
I("(Jz (VL2 2))")
I("(DecR EDX)")
I("(MovRR ECX EDX)")
I("(ShlI8 ECX 02)")
I("(AddRR ECX EBX)")
I("(MovRM ECX ECX)")               # ECX = element
I("(XchgRR EAX ECX)")              # EAX=element, ECX=acc
call("Cons")                       # preserves EBX,EDX
I("(JmpS (VL2 1))")
L("(VL2 2)")
I("(Ret)")

PL("PrError")
L("(ER 1)")
I("(TestRI8 EAX 03)")
I("(Jnz (ER 2))")
I("(PushR EAX)")
I("(MovRM EAX EAX)")
call("Print")
MOVRI("EAX", 0x20)
call("Emit")
I("(PopR EAX)")
I("(MovRMD EAX EAX 04)")
I("(JmpS (ER 1))")
L("(ER 2)")
MOVRI("EAX", 0x0A)
call("Emit")
MOVRI("EAX", 1)
MOVRI("EBX", 1)
I("(Int 80)")

PL("PrExit")
I("(TestRI8 EAX 03)")
I("(Jnz (EX 1))")
I("(MovRM EBX EAX)")
I("(SarI8 EBX 02)")
MOVRI("EAX", 1)
I("(Int 80)")
L("(EX 1)")
MOVRI("EAX", 1)
I("(XorRR EBX EBX)")
I("(Int 80)")

# --- Printer (write-style) ---------------------------------------------------
L("Print")
I("(MovRR ECX EAX)")
I("(AndI8 ECX 03)")
I("(CmpI8 ECX 01)")
I("(Jnz (PR 1))")
I("(Jmp32 PrintNum)")
L("(PR 1)")
I("(CmpI8 ECX 02)")
I("(Jnz (PR 2))")
I("(Jmp32 PrintObj)")
L("(PR 2)")
I("(CmpI8 ECX 03)")
I("(Jnz (PR 3))")
I("(Jmp32 PrintImm)")
L("(PR 3)")
I("(Jmp32 PrintPair)")

L("PrintNum")
I("(SarI8 EAX 02)")
I("(TestRR EAX EAX)")
I("(Jns (PN 1))")
I("(PushR EAX)")
MOVRI("EAX", 0x2D)
call("Emit")
I("(PopR EAX)")
I("(NegR EAX)")
L("(PN 1)")
I("(XorRR EBX EBX)")
MOVRI("ECX", 10)
L("(PN 2)")
I("(XorRR EDX EDX)")
I("(DivR ECX)")
I("(AddI8 EDX 30)")
I("(PushR EDX)")
I("(IncR EBX)")
I("(TestRR EAX EAX)")
I("(Jnz (PN 2))")
L("(PN 3)")
I("(PopR EAX)")
call("Emit")
I("(DecR EBX)")
I("(Jnz (PN 3))")
I("(Ret)")

L("PrintPair")
I("(PushR EAX)")
MOVRI("EAX", 0x28)
call("Emit")
I("(PopR EAX)")
L("(PP 1)")
I("(PushR EAX)")
I("(MovRM EAX EAX)")
call("Print")
I("(PopR EAX)")
I("(MovRMD EAX EAX 04)")
I("(TestRI8 EAX 03)")
I("(Jnz (PP 2))")
I("(PushR EAX)")
MOVRI("EAX", 0x20)
call("Emit")
I("(PopR EAX)")
I("(Jmp32 (PP 1))")
L("(PP 2)")
CMPEAX(NIL)
I("(Jnz (PP 3))")
MOVRI("EAX", 0x29)
I("(Jmp32 Emit)")
L("(PP 3)")
I("(PushR EAX)")
MOVRI("EAX", 0x20)
call("Emit")
MOVRI("EAX", 0x2E)
call("Emit")
MOVRI("EAX", 0x20)
call("Emit")
I("(PopR EAX)")
call("Print")
MOVRI("EAX", 0x29)
I("(Jmp32 Emit)")

L("PrintObj")
I("(SubI8 EAX 02)")
I("(MovRM ECX EAX)")
I("(MovRMD EDX EAX 04)")
I("(SarI8 EDX 02)")
I("(MovRR EBX ECX)")
I("(AndI8 EBX 07)")
I("(TestRR EBX EBX)")
I("(Jnz (PO 1))")
I("(Jmp32 PrintRaw)")
L("(PO 1)")
I("(CmpI8 EBX 01)")
I("(Jz (PO 2))")
I("(CmpI8 EBX 04)")
I("(Jz (PO 3))")
MOVRI("EAX", 0x3F)
I("(Jmp32 Emit)")
L("(PO 2)")
MOVRI("EAX", 0x22)
call("Emit")
I("(AndI8 ECX F8)")
call("PrintRaw")
MOVRI("EAX", 0x22)
I("(Jmp32 Emit)")
# Vector: #(elt elt ...). ECX = car (buffer|4), EDX = element count.
L("(PO 3)")
I("(AndI8 ECX F8)")                # buffer
I("(PushR ECX)")
I("(PushR EDX)")
MOVRI("EAX", 0x23)                 # '#'
call("Emit")
MOVRI("EAX", 0x28)                 # '('
call("Emit")
I("(PopR EDX)")
I("(PopR ECX)")
I("(TestRR EDX EDX)")
I("(Jz32 (PO 6))")                 # empty vector -> ')'
L("(PO 4)")
I("(MovRM EAX ECX)")               # element
I("(PushR ECX)")
I("(PushR EDX)")
call("Print")
I("(PopR EDX)")
I("(PopR ECX)")
I("(AddI8 ECX 04)")
I("(DecR EDX)")
I("(Jz32 (PO 6))")                 # no more -> ')'
I("(PushR ECX)")
I("(PushR EDX)")
MOVRI("EAX", 0x20)                 # ' '
call("Emit")
I("(PopR EDX)")
I("(PopR ECX)")
I("(Jmp32 (PO 4))")
L("(PO 6)")
MOVRI("EAX", 0x29)                 # ')'
I("(Jmp32 Emit)")

L("PrintImm")
CMPEAX(NIL)
I("(Jnz (PI 1))")
MOVRI("EAX", 0x28)
call("Emit")
MOVRI("EAX", 0x29)
I("(Jmp32 Emit)")
L("(PI 1)")
CMPEAX(TRUE)
I("(Jnz (PI 2))")
MOVRI("EAX", 0x23)
call("Emit")
MOVRI("EAX", 0x74)
I("(Jmp32 Emit)")
L("(PI 2)")
CMPEAX(FALSE)
I("(Jnz (PI 3))")
MOVRI("EAX", 0x23)
call("Emit")
MOVRI("EAX", 0x66)
I("(Jmp32 Emit)")
L("(PI 3)")
I("(MovRR ECX EAX)")
I(f"(AndI32 ECX {x8(0xFF)})")
I("(CmpI8 ECX 53)")
I("(Jnz (PI 4))")
I("(PushR EAX)")
MOVRI("EAX", 0x23)
call("Emit")
MOVRI("EAX", 0x5C)
call("Emit")
I("(PopR EAX)")
I("(ShrI8 EAX 08)")
I("(Jmp32 Emit)")
L("(PI 4)")
MOVRI("EAX", 0x3F)
I("(Jmp32 Emit)")

# ===========================================================================
# P1 PART A: 32-bit word ("w32") values.
#
# A w32 is an object cell of NEW subtype 5: cell.car = 5 (payload ptr 0,
# subtype 5), cell.cdr = the RAW 32-bit machine word (NOT a tagged value).
# The boxed value is the object pointer celladdr+2. Because the cdr holds a
# raw word, ONLY the w32 primitives below may touch it; rsc's printer and GC
# never run at qmes runtime, so nothing else inspects a subtype-5 cell.
# All arithmetic uses native 32-bit register ops (no 16-bit limb splitting).
# ===========================================================================

# MakeW32(ECX = raw word) -> boxed w32 in EAX.  Cons preserves ECX.
L("MakeW32")
MOVRI("EAX", 5)                    # car = 5 (payload 0 | subtype 5)
call("Cons")                       # cell: car=5, cdr=ECX (raw word)
I("(OrI8 EAX 02)")                 # object pointer
I("(Ret)")


def w32_load2():
    """Destructure (a b): EAX <- raw a, ECX <- raw b (both from w32 boxes)."""
    I("(MovRMD ECX EAX 04)")       # ECX = (b)
    I("(MovRM ECX ECX)")           # ECX = b box
    I("(MovRM EAX EAX)")           # EAX = a box
    I("(MovRMD EAX EAX 02)")       # EAX = raw a  ([box+2] = celladdr+4 = cdr)
    I("(MovRMD ECX ECX 02)")       # ECX = raw b


def w32_binop(label, opins):
    PL(label)
    w32_load2()
    I(opins)                       # result raw in EAX
    I("(MovRR ECX EAX)")
    I("(Jmp32 MakeW32)")


PL("PrW32FromFix")                 # (w32-from-fixnum n): sign-extend n>>2
I("(MovRM EAX EAX)")               # n fixnum (n*4+1)
I("(SarI8 EAX 02)")                # arithmetic: signed value, sign-extended
I("(MovRR ECX EAX)")
I("(Jmp32 MakeW32)")

PL("PrW32ToFix")                   # (w32->fixnum b): raw -> raw*4+1 (truncates)
I("(MovRM EAX EAX)")               # b box
I("(MovRMD EAX EAX 02)")           # raw word
I("(ShlI8 EAX 02)")
I("(OrI8 EAX 01)")
I("(Ret)")

PL("PrW32Q")                       # (w32? x): #t iff object subtype 5
I("(MovRM EAX EAX)")
I("(MovRR ECX EAX)")
I("(AndI8 ECX 03)")
I("(CmpI8 ECX 02)")                # object pointer?
I("(Jnz (WQ F))")
I("(SubI8 EAX 02)")                # celladdr
I("(MovRM EAX EAX)")               # car
I("(AndI8 EAX 07)")                # subtype
I("(CmpI8 EAX 05)")
I("(Jz (WQ T))")
I("(JmpS (WQ F))")
ret_bool("WQ")

w32_binop("PrW32Add", "(AddRR EAX ECX)")
w32_binop("PrW32Sub", "(SubRR EAX ECX)")   # EAX = a - b
w32_binop("PrW32Mul", "(IMulRR EAX ECX)")  # low 32 bits, wraparound
w32_binop("PrW32And", "(AndRR EAX ECX)")
w32_binop("PrW32Or", "(OrRR EAX ECX)")
w32_binop("PrW32Xor", "(XorRR EAX ECX)")

PL("PrW32Not")                     # (w32-not a)
I("(MovRM EAX EAX)")
I("(MovRMD EAX EAX 02)")           # raw a
I("(NotR EAX)")
I("(MovRR ECX EAX)")
I("(Jmp32 MakeW32)")

# Signed division: cdq; idiv.  a in EAX, b in ECX; quot->EAX, rem->EDX.
PL("PrW32Quot")
w32_load2()
I("(Cdq)")
I("(IDivR ECX)")
I("(MovRR ECX EAX)")
I("(Jmp32 MakeW32)")

PL("PrW32Rem")
w32_load2()
I("(Cdq)")
I("(IDivR ECX)")
I("(MovRR ECX EDX)")
I("(Jmp32 MakeW32)")

# Unsigned division: xor edx,edx; div.
PL("PrW32UQuot")
w32_load2()
I("(XorRR EDX EDX)")
I("(DivR ECX)")
I("(MovRR ECX EAX)")
I("(Jmp32 MakeW32)")

PL("PrW32URem")
w32_load2()
I("(XorRR EDX EDX)")
I("(DivR ECX)")
I("(MovRR ECX EDX)")
I("(Jmp32 MakeW32)")


def w32_shift(label, shins, prefix):
    """(w32-shl/shr/sar a n): n is a small rsc FIXNUM shift count.

    The qfasm assembler has no CL-count (0xD3) shift, and editing the
    assembler is out of scope, so the count-N shift is done as a bounded loop
    of single-bit shifts.  This is correct (and, unlike a hardware CL shift,
    does not mask the count to 5 bits) for any non-negative count.
    """
    PL(label)
    I("(MovRMD ECX EAX 04)")       # ECX = (n)
    I("(MovRM ECX ECX)")           # ECX = n fixnum
    I("(MovRM EAX EAX)")           # EAX = a box
    I("(MovRMD EAX EAX 02)")       # EAX = raw a
    I("(SarI8 ECX 02)")            # ECX = n (int)
    L(f"({prefix} 1)")
    I("(TestRR ECX ECX)")
    I(f"(Jz ({prefix} 2))")
    I(shins)                       # shift EAX by one bit
    I("(DecR ECX)")
    I(f"(JmpS ({prefix} 1))")
    L(f"({prefix} 2)")
    I("(MovRR ECX EAX)")
    I("(Jmp32 MakeW32)")


w32_shift("PrW32Shl", "(ShlI8 EAX 01)", "WSHL")
w32_shift("PrW32Shr", "(ShrI8 EAX 01)", "WSHR")   # logical
w32_shift("PrW32Sar", "(SarI8 EAX 01)", "WSAR")   # arithmetic


def w32_cmp(label, jcc, prefix):
    PL(label)
    w32_load2()                    # EAX = raw a, ECX = raw b
    I("(CmpRR EAX ECX)")           # sets flags for a - b
    I(f"({jcc} ({prefix} T))")
    I(f"(JmpS ({prefix} F))")
    ret_bool(prefix)


w32_cmp("PrW32EqQ", "Jz", "WEQ")
w32_cmp("PrW32LtQ", "Jl", "WLT")     # signed <
w32_cmp("PrW32UltQ", "Jb", "WULT")   # unsigned <

# Raw 32-bit vector-word accessors.  A vector (subtype 4) keeps its element
# buffer at byteptr = (cell.car & ~7); element k lives at byteptr + k*4.
# These read/write a RAW machine word there, bypassing tag interpretation, so
# qmes can pack a Mes cell (three words) into consecutive vector slots.
PL("PrVecRawRef")                  # (vec-raw-ref v k) -> w32 box of raw word
I("(MovRMD ECX EAX 04)")           # (k)
I("(MovRM ECX ECX)")               # k fixnum
I("(AndI8 ECX FC)")                # k*4 (clear the fixnum tag bits)
I("(MovRM EAX EAX)")               # v obj
I("(SubI8 EAX 02)")                # celladdr
I("(MovRM EAX EAX)")               # car = buffer|4
I("(AndI8 EAX F8)")                # buffer
I("(AddRR EAX ECX)")               # &elt[k]
I("(MovRM ECX EAX)")               # raw word
I("(Jmp32 MakeW32)")

PL("PrVecRawSet")                  # (vec-raw-set! v k w): store w's raw word
I("(MovRM ECX EAX)")               # v obj
I("(SubI8 ECX 02)")                # celladdr
I("(MovRM ECX ECX)")               # car = buffer|4
I("(AndI8 ECX F8)")                # buffer
I("(MovRMD EAX EAX 04)")           # (k w)
I("(MovRM EDX EAX)")               # k fixnum
I("(AndI8 EDX FC)")                # k*4
I("(AddRR ECX EDX)")               # &elt[k]
I("(MovRMD EAX EAX 04)")           # (w)
I("(MovRM EAX EAX)")               # w box
I("(MovRMD EAX EAX 02)")           # raw word
I("(MovMR ECX EAX)")               # elt[k] = raw
MOVRI("EAX", UNSPEC)
I("(Ret)")

# ===========================================================================
# DATA
# ===========================================================================
CUR = D
I("(Align4)")
for g in ["GCellFree", "GByteFree", "GInPtr", "GInEnd", "GObList",
          "GTokBuf", "GReadBuf"]:
    L(g)
    init = NIL if g == "GObList" else 0
    I(f"(Dd {x8(init)})")
L("GPeek")
I(f"(Dd {x8(MINUS1)})")
L("WriteChBuf")
I("(Db 00)")
I("(Align4)")
for name, _ in PRIMS:
    L(gv(name))
    I(f"(Dd {x8(0)})")
I("(Align8)")
L("CodeEnd")

# ===========================================================================
# Emit as chained macro rules, like build_scheme0's (Z n) blocks.
# ===========================================================================
BLOCK = 24


def emit_macro(top_head, chain_head, items):
    blocks = [items[i:i + BLOCK] for i in range(0, len(items), BLOCK)]
    for bi, blk in enumerate(blocks):
        if bi == 0:
            print(f"(Rule ({top_head} rest)")
        else:
            print(f"(Rule ({chain_head} {bi} rest)")
        for ins in blk:
            print(f"  (Ins {ins}")
        if bi + 1 < len(blocks):
            print(f"  ({chain_head} {bi + 1} rest)" + ")" * len(blk) + ")")
        else:
            print("  rest" + ")" * len(blk) + ")")


def main():
    print("; rsc-runtime: fixed assembly runtime for Stage 4 (rsc.scm).")
    print("; GENERATED by tools/generate_rsc_runtime.py -- edit the builder.")
    print("; Provides (RuntimeCode rest)/(RuntimeData rest) macros plus the")
    print("; DObj/MovRIObj directives, all consumed by compiled rsc output.")
    print()
    print("; Extra directives: object-pointer constants (label address + 2).")
    print("(Size (DObj l)) (Small 4)")
    print("(Pass2 (Ins (DObj l) rest) pc sym)"
          " (Bytes (LEB (Add32 (VAddr (Lookup l sym)) (Small 2)))"
          " (Pass2 rest (Add32 pc (Small 4)) sym))")
    print("(Size (MovRIObj r l)) (Small 5)")
    print("(Pass2 (Ins (MovRIObj r l) rest) pc sym)"
          " (Bytes (MovIB r) (LEB (Add32 (VAddr (Lookup l sym)) (Small 2)))"
          " (Pass2 rest (Add32 pc (Small 5)) sym))")
    print()
    emit_macro("RuntimeCode", "RTC", C)
    print()
    emit_macro("RuntimeData", "RTD", D)


if __name__ == "__main__":
    main()
