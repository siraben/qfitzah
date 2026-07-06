#!/usr/bin/env python3
"""Emit bootstrap/scheme0.qfasm, the Stage 2 minimal Scheme interpreter.

This is a formatter, not a compiler: the SOURCE list below is literal qfasm
instructions, one per entry, in order. The script only handles block
chaining (one rewrite rule per ~24 instructions so the committed file stays
flat), paren balancing, and hex formatting of 32-bit literals. The emitted
bootstrap/scheme0.qfasm is committed and is what the seed assembles.

Value representation (32-bit words):
  tag 00  pair pointer (8-byte cell: car, cdr)
  tag 01  fixnum, value = word >> 2 (30-bit, wraps)
  tag 10  object pointer -> cell at word-2; low 3 bits of the cell's car
          are a subtype: 0 symbol, 1 string, 2 closure, 3 primitive.
          For symbols/strings: car = byte-pointer|sub, cdr = length fixnum.
          For closures: car = pair(params, pair(body-list, env))|2.
          For primitives: car = code-address|3, cdr = arity fixnum.
  tag 11  immediates: 03 nil, 13 #t, 23 #f, 33 eof, 43 unspecified,
          (code<<8)|53 characters.

Registers: args/results in EAX, ECX, EDX; EBX and ESI/EDI are free
scratch. No frame pointer; the machine stack holds temporaries.
ReadCh/PeekCh preserve EBX/ECX/EDX; Emit preserves EBX/ECX/EDX;
Cons preserves ECX/EDX.

Run: python3 tools/build_scheme0.py > bootstrap/scheme0.qfasm
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

S = []  # the program: instruction/label sexps in order


def I(text):
    S.append(text)


def L(name):
    S.append(f"(Label {name})")


def PL(name):
    """Primitive entry point: 8-aligned so `addr|3` tagging is lossless."""
    I("(Align8)")
    L(name)


def MOVRI(r, v):
    I(f"(MovRI {r} {imm(v)})")


def CMPEAX(v):
    I(f"(CmpEaxI32 {imm(v)})")


def emit_call(target):
    I(f"(Call {target})")


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
# Special-form symbols and primitives, both bound during startup.
SPECIALS = [("GSymQuote", "LQuote", "quote"), ("GSymIf", "LIf", "if"),
            ("GSymDefine", "LDefine", "define"), ("GSymSet", "LSet", "set!"),
            ("GSymLambda", "LLambda", "lambda"),
            ("GSymBegin", "LBegin", "begin"), ("GSymLet", "LLet", "let"),
            ("GSymCond", "LCond", "cond"), ("GSymAnd", "LAnd", "and"),
            ("GSymOr", "LOr", "or"), ("GSymElse", "LElse", "else")]

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
         ("error", "PrError"), ("exit", "PrExit")]

L("Start")
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
for gname, lbl, text in SPECIALS:
    I(f"(MovRILabel EAX {lbl})")
    MOVRI("ECX", len(text))
    emit_call("Intern")
    I(f"(MovMemLR {gname} EAX)")
for pi, (name, code) in enumerate(PRIMS):
    I(f"(MovRILabel EAX (LPN {pi}))")
    MOVRI("ECX", len(name))
    emit_call("Intern")
    I(f"(MovRILabel ECX {code})")
    emit_call("DefPrim")

L("MainLoop")
emit_call("ReadExpr")
CMPEAX(EOFV)
I("(Jnz (M 1))")
MOVRI("EAX", 1)                       # exit(0)
I("(XorRR EBX EBX)")
I("(Int 80)")
L("(M 1)")
I("(MovRMemL ECX GEnv)")
emit_call("Eval")
CMPEAX(UNSPEC)
I("(Jz MainLoop2)")
emit_call("Print")
MOVRI("EAX", 0x0A)
emit_call("Emit")
L("MainLoop2")
I("(Jmp32 MainLoop)")

# DefPrim(EAX = symbol, ECX = code address): bind a primitive in GEnv.
L("DefPrim")
I("(PushR EAX)")
I("(MovRR EAX ECX)")
I("(OrI8 EAX 03)")                    # payload | primitive subtype
MOVRI("ECX", 1)                       # meta: fixnum 0
emit_call("Cons")
I("(OrI8 EAX 02)")
I("(MovRR ECX EAX)")
I("(PopR EAX)")
emit_call("Cons")                     # (sym . prim)
I("(MovRMemL ECX GEnv)")
emit_call("Cons")
I("(MovMemLR GEnv EAX)")
I("(Ret)")

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
L("Emit")                             # write the byte in AL to stdout
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

L("PrintRaw")                         # write(1, ECX, EDX); clobbers EAX EBX
MOVRI("EAX", 4)
MOVRI("EBX", 1)
I("(Int 80)")
I("(Ret)")

L("ErrTok")                           # parse error: print "!\n", exit 1
MOVRI("EAX", 0x21)
emit_call("Emit")
MOVRI("EAX", 0x0A)
emit_call("Emit")
MOVRI("EAX", 1)
MOVRI("EBX", 1)
I("(Int 80)")

# ---------------------------------------------------------------------------
# Allocation
# ---------------------------------------------------------------------------
L("Cons")                             # Cons(EAX, ECX) -> pair; keeps ECX EDX
I("(PushR EDX)")
I("(MovRMemL EDX GCellFree)")
I("(MovMR EDX EAX)")
I("(MovMDR EDX 04 ECX)")
I("(MovRR EAX EDX)")
I("(AddI8 EDX 08)")
I("(MovMemLR GCellFree EDX)")
I("(PopR EDX)")
I("(Ret)")

# AllocObj(EAX=src bytes, ECX=len, EDX=subtag) -> tagged object
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
I("(PopR EAX)")                       # start of copied bytes (8-aligned)
I("(PopR EDX)")
I("(OrRR EAX EDX)")                   # payload | subtag
I("(PushR EAX)")
I("(MovRR EAX ECX)")
I("(ShlI8 EAX 02)")
I("(OrI8 EAX 01)")                    # length as fixnum
I("(MovRR ECX EAX)")
I("(PopR EAX)")
emit_call("Cons")
I("(OrI8 EAX 02)")                    # object tag
I("(Ret)")

# ---------------------------------------------------------------------------
# Input: buffered ReadCh (-1 on EOF), one-slot Peek
# ---------------------------------------------------------------------------
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
I("(PushR EBX)")                      # refill
I("(PushR EDX)")
MOVRI("EAX", 3)                       # __NR_read
I("(XorRR EBX EBX)")
I("(MovRMemL ECX GReadBuf)")
MOVRI("EDX", 0x01000000)
I("(Int 80)")
I("(TestRR EAX EAX)")
I("(Jg (RC 2))")
I("(PopR EDX)")                       # EOF (or error): return -1
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
emit_call("ReadCh")
I("(MovMemLR GPeek EAX)")
I("(Ret)")

L("SkipWS")
L("(SW 1)")
emit_call("ReadCh")
I("(CmpALI8 20)")
I("(Jz (SW 1))")
I("(CmpALI8 09)")
I("(Jz (SW 1))")
I("(CmpALI8 0A)")
I("(Jz (SW 1))")
I("(CmpALI8 0D)")
I("(Jz (SW 1))")
I("(CmpALI8 3B)")
I("(Jnz (SW 3))")
L("(SW 2)")                           # comment to end of line
emit_call("ReadCh")
CMPEAX(MINUS1)
I("(Jz (SW 4))")
I("(CmpALI8 0A)")
I("(Jz (SW 1))")
I("(JmpS (SW 2))")
L("(SW 3)")
I("(MovMemLR GPeek EAX)")             # unget (-1 is harmless)
L("(SW 4)")
I("(Ret)")

# ---------------------------------------------------------------------------
# Reader
# ---------------------------------------------------------------------------
L("ReadExpr")
emit_call("SkipWS")
emit_call("ReadCh")
CMPEAX(MINUS1)
I("(Jnz (RE 1))")
MOVRI("EAX", EOFV)
I("(Ret)")
L("(RE 1)")
I("(CmpALI8 28)")                     # (
I("(Jnz (RE 2))")
I("(Jmp32 ReadList)")
L("(RE 2)")
I("(CmpALI8 29)")                     # stray )
I("(Jnz (RE 3))")
I("(Jmp32 ErrTok)")
L("(RE 3)")
I("(CmpALI8 27)")                     # 'x -> (quote x)
I("(Jnz (RE 4))")
emit_call("ReadExpr")
MOVRI("ECX", NIL)
emit_call("Cons")
I("(MovRR ECX EAX)")
I("(MovRMemL EAX GSymQuote)")
I("(Jmp32 Cons)")
L("(RE 4)")
I("(CmpALI8 23)")                     # #
I("(Jnz (RE 5))")
I("(Jmp32 ReadHash)")
L("(RE 5)")
I("(CmpALI8 22)")                     # "
I("(Jnz (RE 6))")
I("(Jmp32 ReadString)")
L("(RE 6)")
I("(CmpALI8 30)")
I("(Jb (RE 7))")
I("(CmpALI8 39)")
I("(Ja (RE 7))")
I("(XorRR ECX ECX)")                  # positive number
I("(Jmp32 ReadNum)")
L("(RE 7)")
I("(CmpALI8 2D)")                     # - : number if a digit follows
I("(Jnz (RE 9))")
I("(PushR EAX)")
emit_call("PeekCh")
I("(CmpALI8 30)")
I("(Jb (RE 8))")
I("(CmpALI8 39)")
I("(Ja (RE 8))")
I("(PopR EAX)")
emit_call("ReadCh")                   # first digit
MOVRI("ECX", 1)
I("(Jmp32 ReadNum)")
L("(RE 8)")
I("(PopR EAX)")
L("(RE 9)")
I("(Jmp32 ReadSym)")

# ReadNum: EAX = first digit char, ECX = 1 if negative
L("ReadNum")
I("(PushR ECX)")
I("(SubI8 EAX 30)")
I("(MovRR ECX EAX)")                  # accumulator
L("(RN 1)")
emit_call("PeekCh")
I("(CmpALI8 30)")
I("(Jb (RN 2))")
I("(CmpALI8 39)")
I("(Ja (RN 2))")
emit_call("ReadCh")
I("(SubI8 EAX 30)")
I("(MovRR EDX ECX)")
I("(ShlI8 ECX 03)")
I("(ShlI8 EDX 01)")
I("(AddRR ECX EDX)")
I("(AddRR ECX EAX)")
I("(JmpS (RN 1))")
L("(RN 2)")
I("(MovRR EAX ECX)")
I("(PopR ECX)")
I("(TestRR ECX ECX)")
I("(Jz (RN 3))")
I("(NegR EAX)")
L("(RN 3)")
I("(ShlI8 EAX 02)")
I("(OrI8 EAX 01)")
I("(Ret)")

L("ReadList")
emit_call("SkipWS")
emit_call("PeekCh")
I("(CmpALI8 29)")
I("(Jnz (RL 1))")
emit_call("ReadCh")                   # consume )
MOVRI("EAX", NIL)
I("(Ret)")
L("(RL 1)")
CMPEAX(MINUS1)
I("(Jnz (RL 2))")
I("(Jmp32 ErrTok)")                   # EOF inside a list
L("(RL 2)")
I("(CmpALI8 2E)")                     # . tail
I("(Jnz (RL 4))")
emit_call("ReadCh")                   # consume the dot
emit_call("PeekCh")
I("(CmpALI8 20)")
I("(Jz (RL 3))")
I("(CmpALI8 09)")
I("(Jz (RL 3))")
I("(CmpALI8 0A)")
I("(Jz (RL 3))")
I("(CmpALI8 0D)")
I("(Jz (RL 3))")
I("(CmpALI8 28)")
I("(Jz (RL 3))")
I("(Jmp32 ErrTok)")                   # symbols may not start with .
L("(RL 3)")
emit_call("ReadExpr")
I("(PushR EAX)")
emit_call("SkipWS")
emit_call("ReadCh")
I("(CmpALI8 29)")
I("(Jz (RL 5))")
I("(Jmp32 ErrTok)")
L("(RL 5)")
I("(PopR EAX)")
I("(Ret)")
L("(RL 4)")
emit_call("ReadExpr")
I("(PushR EAX)")
emit_call("ReadList")
I("(MovRR ECX EAX)")
I("(PopR EAX)")
I("(Jmp32 Cons)")

L("ReadHash")
emit_call("ReadCh")
I("(CmpALI8 74)")                     # #t
I("(Jnz (RH 1))")
MOVRI("EAX", TRUE)
I("(Ret)")
L("(RH 1)")
I("(CmpALI8 66)")                     # #f
I("(Jnz (RH 2))")
MOVRI("EAX", FALSE)
I("(Ret)")
L("(RH 2)")
I("(CmpALI8 5C)")                     # #\char
I("(Jz (RH 3))")
I("(Jmp32 ErrTok)")
L("(RH 3)")
emit_call("ReadCh")
I("(PushR EAX)")
emit_call("PeekCh")
I("(CmpALI8 61)")
I("(Jb (RH 5))")
I("(CmpALI8 7A)")
I("(Ja (RH 5))")
L("(RH 4)")                           # named char: eat trailing letters
emit_call("ReadCh")
emit_call("PeekCh")
I("(CmpALI8 61)")
I("(Jb (RH 40))")
I("(CmpALI8 7A)")
I("(Jbe (RH 4))")
L("(RH 40)")
I("(PopR EAX)")                       # map by first letter
I("(CmpALI8 73)")                     # space
I("(Jnz (RH 41))")
MOVRI("EAX", 0x20)
I("(JmpS (RH 6))")
L("(RH 41)")
I("(CmpALI8 6E)")                     # newline
I("(Jnz (RH 42))")
MOVRI("EAX", 0x0A)
I("(JmpS (RH 6))")
L("(RH 42)")
I("(CmpALI8 74)")                     # tab
I("(Jnz (RH 43))")
MOVRI("EAX", 0x09)
I("(JmpS (RH 6))")
L("(RH 43)")
I("(Jmp32 ErrTok)")
L("(RH 5)")
I("(PopR EAX)")
L("(RH 6)")
I("(ShlI8 EAX 08)")
I("(OrI8 EAX 53)")
I("(Ret)")

L("ReadString")
I("(MovRMemL EDX GTokBuf)")
L("(RS 1)")
emit_call("ReadCh")
CMPEAX(MINUS1)
I("(Jnz (RS 10))")
I("(Jmp32 ErrTok)")
L("(RS 10)")
I("(CmpALI8 22)")
I("(Jz (RS 3))")
I("(CmpALI8 5C)")
I("(Jnz (RS 2))")
emit_call("ReadCh")                   # escape: \n special, else literal
I("(CmpALI8 6E)")
I("(Jnz (RS 2))")
MOVRI("EAX", 0x0A)
L("(RS 2)")
I("(MovbMR EDX EAX)")
I("(IncR EDX)")
I("(Jmp32 (RS 1))")
L("(RS 3)")
I("(MovRMemL EAX GTokBuf)")
I("(MovRR ECX EDX)")
I("(SubRR ECX EAX)")
MOVRI("EDX", 1)                       # subtype: string
I("(Jmp32 AllocObj)")

L("ReadSym")                          # first char in AL
I("(MovRMemL EDX GTokBuf)")
I("(MovbMR EDX EAX)")
I("(IncR EDX)")
L("(RY 1)")
emit_call("ReadCh")
CMPEAX(MINUS1)
I("(Jz (RY 2))")
I("(CmpALI8 20)")
I("(Jz (RY 2))")
I("(CmpALI8 09)")
I("(Jz (RY 2))")
I("(CmpALI8 0A)")
I("(Jz (RY 2))")
I("(CmpALI8 0D)")
I("(Jz (RY 2))")
I("(CmpALI8 28)")
I("(Jz (RY 2))")
I("(CmpALI8 29)")
I("(Jz (RY 2))")
I("(CmpALI8 22)")
I("(Jz (RY 2))")
I("(CmpALI8 3B)")
I("(Jz (RY 2))")
I("(MovbMR EDX EAX)")
I("(IncR EDX)")
I("(JmpS (RY 1))")
L("(RY 2)")
I("(MovMemLR GPeek EAX)")             # unget delimiter
I("(MovRMemL EAX GTokBuf)")
I("(MovRR ECX EDX)")
I("(SubRR ECX EAX)")
I("(Jmp32 Intern)")

L("Intern")                           # (EAX=bytes, ECX=len) -> symbol
I("(MovRMemL EDX GObList)")
L("(IN 1)")
I("(TestRI8 EDX 03)")
I("(Jz (IN 2))")
I("(XorRR EDX EDX)")                  # miss: make a new symbol (subtype 0)
emit_call("AllocObj")
I("(PushR EAX)")
I("(MovRMemL ECX GObList)")
emit_call("Cons")
I("(MovMemLR GObList EAX)")
I("(PopR EAX)")
I("(Ret)")
L("(IN 2)")
I("(MovRM EBX EDX)")                  # candidate symbol
I("(MovRR EDI EBX)")
I("(SubI8 EDI 02)")                   # its cell
I("(MovRMD ESI EDI 04)")
I("(SarI8 ESI 02)")                   # its length
I("(CmpRR ESI ECX)")
I("(Jnz (IN 3))")
I("(MovRM ESI EDI)")                  # its bytes (subtype 0: clean ptr)
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

# ---------------------------------------------------------------------------
# Evaluator. Eval(EAX=expr, ECX=env) -> EAX. Tail positions loop back to
# EvalTop instead of recursing, so iterative Scheme runs in constant stack.
# ---------------------------------------------------------------------------
L("Eval")
L("EvalTop")
I("(MovRR EBX EAX)")
I("(AndI8 EBX 03)")
I("(CmpI8 EBX 01)")                   # fixnum
I("(Jnz (EV 1))")
I("(Ret)")
L("(EV 1)")
I("(CmpI8 EBX 03)")                   # immediate
I("(Jnz (EV 2))")
I("(Ret)")
L("(EV 2)")
I("(CmpI8 EBX 02)")                   # object
I("(Jnz (EV 4))")
I("(MovRR EDX EAX)")
I("(SubI8 EDX 02)")
I("(MovRM EDX EDX)")
I("(TestRI8 EDX 07)")
I("(Jz (EV 3))")
I("(Ret)")                            # strings etc. self-evaluate
L("(EV 3)")
emit_call("LookupPair")               # symbol
I("(MovRMD EAX EAX 04)")
I("(Ret)")
L("(EV 4)")                           # pair: special form or application
I("(MovRM EDX EAX)")
for gname, target in [("GSymQuote", None), ("GSymIf", "EvIf"),
                      ("GSymDefine", "EvDefine"), ("GSymSet", "EvSet"),
                      ("GSymLambda", "EvLambda"), ("GSymBegin", "EvBegin"),
                      ("GSymLet", "EvLet"), ("GSymCond", "EvCond"),
                      ("GSymAnd", "EvAnd"), ("GSymOr", "EvOr")]:
    I(f"(MovRMemL EBX {gname})")
    I("(CmpRR EDX EBX)")
    I(f"(Jnz (EV 5 {gname}))")
    if target is None:                # quote: return cadr
        I("(MovRMD EAX EAX 04)")
        I("(MovRM EAX EAX)")
        I("(Ret)")
    else:
        I(f"(Jmp32 {target})")
    L(f"(EV 5 {gname})")
# application: f = Eval(car), args = EvList(cdr), then Apply
I("(PushR ECX)")
I("(PushR EAX)")
I("(MovRM EAX EAX)")
emit_call("Eval")
I("(PopR EDX)")                       # expr
I("(PopR ECX)")                       # env
I("(PushR EAX)")                      # f
I("(MovRMD EAX EDX 04)")
emit_call("EvList")
I("(MovRR EDX EAX)")
I("(PopR EAX)")
I("(Jmp32 Apply)")

# LookupPair(EAX=symbol, ECX=env) -> binding pair; falls back to the
# current global environment so top-level recursion works.
L("LookupPair")
I("(XorRR EBX EBX)")
L("(LK 1)")
I("(TestRI8 ECX 03)")
I("(Jnz (LK 3))")
I("(MovRM EDX ECX)")
I("(MovRM EDI EDX)")
I("(CmpRR EDI EAX)")
I("(Jz (LK 2))")
I("(MovRMD ECX ECX 04)")
I("(JmpS (LK 1))")
L("(LK 2)")
I("(MovRR EAX EDX)")
I("(Ret)")
L("(LK 3)")
I("(TestRR EBX EBX)")
I("(Jnz (LK 4))")
I("(IncR EBX)")
I("(MovRMemL ECX GEnv)")
I("(JmpS (LK 1))")
L("(LK 4)")                           # unbound: print name, "?", exit 1
emit_call("Print")
MOVRI("EAX", 0x3F)
emit_call("Emit")
MOVRI("EAX", 0x0A)
emit_call("Emit")
MOVRI("EAX", 1)
MOVRI("EBX", 1)
I("(Int 80)")

L("EvList")                           # (EAX=exprs, ECX=env) -> values
I("(TestRI8 EAX 03)")
I("(Jz (EL 1))")
MOVRI("EAX", NIL)
I("(Ret)")
L("(EL 1)")
I("(PushR ECX)")
I("(PushR EAX)")
I("(MovRM EAX EAX)")
emit_call("Eval")
I("(PopR EDX)")
I("(PopR ECX)")
I("(PushR EAX)")
I("(MovRMD EAX EDX 04)")
emit_call("EvList")
I("(MovRR ECX EAX)")
I("(PopR EAX)")
I("(Jmp32 Cons)")

L("EvIf")                             # (if c t [e])
I("(MovRMD EDX EAX 04)")
I("(PushR ECX)")
I("(PushR EDX)")
I("(MovRM EAX EDX)")
emit_call("Eval")
I("(PopR EDX)")
I("(PopR ECX)")
CMPEAX(FALSE)
I("(MovRMD EDX EDX 04)")              # (t [e]); mov keeps flags
I("(Jz (IF 1))")
I("(MovRM EAX EDX)")
I("(Jmp32 EvalTop)")
L("(IF 1)")
I("(MovRMD EDX EDX 04)")
I("(TestRI8 EDX 03)")
I("(Jz (IF 2))")
MOVRI("EAX", UNSPEC)
I("(Ret)")
L("(IF 2)")
I("(MovRM EAX EDX)")
I("(Jmp32 EvalTop)")

L("EvDefine")                         # (define x v) | (define (f . as) ...)
I("(MovRMD EDX EAX 04)")
I("(MovRM EBX EDX)")
I("(TestRI8 EBX 03)")
I("(Jz (DF 1))")
I("(PushR EBX)")                      # plain variable
I("(MovRMD EDX EDX 04)")
I("(MovRM EAX EDX)")
emit_call("Eval")
I("(MovRR EDX EAX)")
I("(PopR EAX)")
I("(MovRR ECX EDX)")
emit_call("Cons")                     # (name . value)
I("(MovRMemL ECX GEnv)")
emit_call("Cons")
I("(MovMemLR GEnv EAX)")
MOVRI("EAX", UNSPEC)
I("(Ret)")
L("(DF 1)")                           # sugar: build (lambda params body...)
I("(PushR ECX)")
I("(MovRMD EAX EDX 04)")              # body list
I("(MovRR ECX EAX)")
I("(MovRMD EAX EBX 04)")              # params
emit_call("Cons")                     # (params . body)
I("(MovRR ECX EAX)")
I("(MovRMemL EAX GSymLambda)")
emit_call("Cons")                     # (lambda params . body)
I("(MovRM EBX EBX)")                  # name
I("(PopR ECX)")
I("(PushR EBX)")
emit_call("Eval")                     # the closure
I("(MovRR ECX EAX)")
I("(PopR EAX)")
emit_call("Cons")                     # (name . closure)
I("(MovRMemL ECX GEnv)")
emit_call("Cons")
I("(MovMemLR GEnv EAX)")
MOVRI("EAX", UNSPEC)
I("(Ret)")

L("EvSet")                            # (set! x v)
I("(MovRMD EDX EAX 04)")
I("(PushR EDX)")
I("(PushR ECX)")
I("(MovRM EAX EDX)")
emit_call("LookupPair")
I("(PopR ECX)")
I("(PopR EDX)")
I("(PushR EAX)")
I("(MovRMD EDX EDX 04)")
I("(MovRM EAX EDX)")
emit_call("Eval")
I("(PopR ECX)")
I("(MovMDR ECX 04 EAX)")
MOVRI("EAX", UNSPEC)
I("(Ret)")

L("EvLambda")                         # (lambda params body...)
I("(MovRMD EDX EAX 04)")              # (params . body)
I("(MovRMD EAX EDX 04)")              # body
emit_call("Cons")                     # (body . env)
I("(MovRR ECX EAX)")
I("(MovRM EAX EDX)")                  # params
emit_call("Cons")                     # (params body . env)
I("(OrI8 EAX 02)")                    # closure subtype
MOVRI("ECX", 1)
emit_call("Cons")                     # object cell
I("(OrI8 EAX 02)")
I("(Ret)")

L("EvBegin")
I("(MovRMD EAX EAX 04)")
I("(Jmp32 SeqTail)")

# SeqTail(EAX=expr list, ECX=env): evaluate all, last in tail position.
L("SeqTail")
I("(TestRI8 EAX 03)")
I("(Jz (SQ 1))")
MOVRI("EAX", UNSPEC)
I("(Ret)")
L("(SQ 1)")
I("(MovRMD EDX EAX 04)")
I("(TestRI8 EDX 03)")
I("(Jnz (SQ 2))")
I("(PushR ECX)")
I("(PushR EDX)")
I("(MovRM EAX EAX)")
emit_call("Eval")
I("(PopR EAX)")
I("(PopR ECX)")
I("(JmpS (SQ 1))")
L("(SQ 2)")
I("(MovRM EAX EAX)")
I("(Jmp32 EvalTop)")

L("EvLet")                            # (let ((n v) ...) body...)
I("(MovRMD EDX EAX 04)")              # (bindings . body)
I("(MovRM EBX EDX)")                  # bindings
I("(PushR EDX)")
I("(PushR ECX)")                      # newenv starts as env
L("(LT 1)")
I("(TestRI8 EBX 03)")
I("(Jnz (LT 2))")
I("(MovRM EDX EBX)")                  # binding (n v)
I("(PushR EBX)")
I("(PushR ECX)")
I("(MovRMD EAX EDX 04)")
I("(MovRM EAX EAX)")                  # v expr
I("(PushR EDX)")
emit_call("Eval")                     # in the ORIGINAL env
I("(PopR EDX)")
I("(MovRR ECX EAX)")
I("(MovRM EAX EDX)")
emit_call("Cons")                     # (n . value)
I("(PopR ECX)")                       # original env
I("(PopR EBX)")                       # bindings
I("(PopR EDX)")                       # newenv
I("(PushR ECX)")
I("(MovRR ECX EDX)")
emit_call("Cons")
I("(PopR ECX)")
I("(PushR EAX)")                      # updated newenv
I("(MovRMD EBX EBX 04)")
I("(JmpS (LT 1))")
L("(LT 2)")
I("(PopR ECX)")                       # newenv
I("(PopR EAX)")                       # (bindings . body)
I("(MovRMD EAX EAX 04)")
I("(Jmp32 SeqTail)")

L("EvCond")
I("(MovRMD EBX EAX 04)")
L("(CO 1)")
I("(TestRI8 EBX 03)")
I("(Jnz (CO 5))")
I("(MovRM EDX EBX)")                  # clause
I("(MovRM EAX EDX)")                  # test
I("(MovRMemL EDI GSymElse)")
I("(CmpRR EAX EDI)")
I("(Jz (CO 4))")
I("(PushR EBX)")
I("(PushR ECX)")
I("(PushR EDX)")
emit_call("Eval")
I("(PopR EDX)")
I("(PopR ECX)")
I("(PopR EBX)")
CMPEAX(FALSE)
I("(Jnz (CO 2))")
I("(MovRMD EBX EBX 04)")
I("(JmpS (CO 1))")
L("(CO 2)")
I("(MovRMD EDX EDX 04)")              # clause body
I("(TestRI8 EDX 03)")
I("(Jnz (CO 3))")
I("(MovRR EAX EDX)")
I("(Jmp32 SeqTail)")
L("(CO 3)")
I("(Ret)")                            # empty body: the test value
L("(CO 4)")
I("(MovRMD EAX EDX 04)")
I("(Jmp32 SeqTail)")
L("(CO 5)")
MOVRI("EAX", UNSPEC)
I("(Ret)")

L("EvAnd")
I("(MovRMD EBX EAX 04)")
I("(TestRI8 EBX 03)")
I("(Jz (AN 1))")
MOVRI("EAX", TRUE)
I("(Ret)")
L("(AN 1)")
I("(MovRMD EDX EBX 04)")
I("(TestRI8 EDX 03)")
I("(Jnz (AN 3))")
I("(PushR EBX)")
I("(PushR ECX)")
I("(MovRM EAX EBX)")
emit_call("Eval")
I("(PopR ECX)")
I("(PopR EBX)")
CMPEAX(FALSE)
I("(Jz (AN 2))")
I("(MovRMD EBX EBX 04)")
I("(JmpS (AN 1))")
L("(AN 2)")
I("(Ret)")
L("(AN 3)")
I("(MovRM EAX EBX)")
I("(Jmp32 EvalTop)")

L("EvOr")
I("(MovRMD EBX EAX 04)")
I("(TestRI8 EBX 03)")
I("(Jz (OR 1))")
MOVRI("EAX", FALSE)
I("(Ret)")
L("(OR 1)")
I("(MovRMD EDX EBX 04)")
I("(TestRI8 EDX 03)")
I("(Jnz (OR 3))")
I("(PushR EBX)")
I("(PushR ECX)")
I("(MovRM EAX EBX)")
emit_call("Eval")
I("(PopR ECX)")
I("(PopR EBX)")
CMPEAX(FALSE)
I("(Jnz (OR 2))")
I("(MovRMD EBX EBX 04)")
I("(JmpS (OR 1))")
L("(OR 2)")
I("(Ret)")
L("(OR 3)")
I("(MovRM EAX EBX)")
I("(Jmp32 EvalTop)")

# Apply(EAX=procedure, EDX=args)
L("Apply")
I("(MovRR EBX EAX)")
I("(AndI8 EBX 03)")
I("(CmpI8 EBX 02)")
I("(Jz (AP 1))")
I("(Jmp32 ErrApply)")
L("(AP 1)")
I("(MovRR ESI EAX)")
I("(SubI8 ESI 02)")
I("(MovRM EDI ESI)")                  # payload | subtype
I("(MovRR EBX EDI)")
I("(AndI8 EBX 07)")
I("(CmpI8 EBX 03)")
I("(Jnz (AP 2))")
I("(AndI8 EDI F8)")                   # primitive: jump to its code
I("(MovRR EAX EDX)")
I("(JmpR EDI)")
L("(AP 2)")
I("(CmpI8 EBX 02)")
I("(Jz (AP 3))")
I("(Jmp32 ErrApply)")
L("(AP 3)")                           # closure
I("(AndI8 EDI F8)")
I("(MovRM EBX EDI)")                  # params
I("(MovRMD ESI EDI 04)")              # (body . cenv)
I("(MovRMD ECX ESI 04)")              # newenv := cenv
L("(AP 4)")
I("(TestRI8 EBX 03)")
I("(Jz (AP 6))")
I("(MovRR EAX EBX)")
I("(AndI8 EAX 03)")
I("(CmpI8 EAX 02)")
I("(Jnz (AP 5))")
I("(MovRR EAX EBX)")                  # rest parameter
I("(PushR ECX)")
I("(MovRR ECX EDX)")
emit_call("Cons")
I("(PopR ECX)")
emit_call("Cons")
I("(MovRR ECX EAX)")
I("(JmpS (AP 7))")
L("(AP 5)")
I("(MovRR EAX EBX)")
CMPEAX(NIL)
I("(Jnz (AP 9))")
I("(TestRI8 EDX 03)")
I("(Jz (AP 9))")                      # too many arguments
I("(JmpS (AP 7))")
L("(AP 6)")
I("(TestRI8 EDX 03)")
I("(Jnz (AP 9))")                     # too few arguments
I("(PushR ECX)")
I("(MovRM EAX EBX)")
I("(MovRM ECX EDX)")
emit_call("Cons")                     # (param . arg)
I("(PopR ECX)")
emit_call("Cons")
I("(MovRR ECX EAX)")
I("(MovRMD EBX EBX 04)")
I("(MovRMD EDX EDX 04)")
I("(JmpS (AP 4))")
L("(AP 7)")
I("(MovRM EAX ESI)")                  # body list
I("(Jmp32 SeqTail)")
L("(AP 9)")
I("(Jmp32 ErrApply)")

L("ErrApply")                         # "!a\n", exit 1
MOVRI("EAX", 0x21)
emit_call("Emit")
MOVRI("EAX", 0x61)
emit_call("Emit")
MOVRI("EAX", 0x0A)
emit_call("Emit")
MOVRI("EAX", 1)
MOVRI("EBX", 1)
I("(Int 80)")


# ---------------------------------------------------------------------------
# Primitives. Convention: EAX = evaluated argument list; result in EAX.
# ---------------------------------------------------------------------------
def ret_bool(prefix):
    """Emit shared true/false tails; jump Jz to (prefix T) for #t."""
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
MOVRI("ECX", 1)                       # fixnum 0
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
I("(MovRM ECX EAX)")                  # first argument
I("(MovRMD EAX EAX 04)")
I("(TestRI8 EAX 03)")
I("(Jz (SB 1))")
MOVRI("EAX", 2)                       # unary: 2 - a negates a fixnum
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
MOVRI("ECX", 1)                       # raw 1
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
    I("(CmpRR ECX EAX)")              # first vs second, signed on tagged
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
I("(AndI8 ECX F8)")                   # string: raw bytes
I("(MovRMD EDX EDX 04)")
I("(SarI8 EDX 02)")
emit_call("PrintRaw")
MOVRI("EAX", UNSPEC)
I("(Ret)")
L("(DS 2)")
I("(CmpI8 ECX 03)")
I("(Jnz (DS 3))")
I("(MovRR EDX EAX)")
I(f"(AndI32 EDX {x8(0xFF)})")
I("(CmpI8 EDX 53)")
I("(Jnz (DS 3))")
I("(ShrI8 EAX 08)")                   # char: the raw byte
emit_call("Emit")
MOVRI("EAX", UNSPEC)
I("(Ret)")
L("(DS 3)")
emit_call("Print")
MOVRI("EAX", UNSPEC)
I("(Ret)")

PL("PrWrite")
I("(MovRM EAX EAX)")
emit_call("Print")
MOVRI("EAX", UNSPEC)
I("(Ret)")

PL("PrNewline")
MOVRI("EAX", 0x0A)
emit_call("Emit")
MOVRI("EAX", UNSPEC)
I("(Ret)")

PL("PrReadChar")
emit_call("ReadCh")
CMPEAX(MINUS1)
I("(Jz (RDC 1))")
I("(ShlI8 EAX 08)")
I("(OrI8 EAX 53)")
I("(Ret)")
L("(RDC 1)")
MOVRI("EAX", EOFV)
I("(Ret)")

PL("PrPeekChar")
emit_call("PeekCh")
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
I("(MovRM ECX EAX)")                  # string
I("(MovRMD EAX EAX 04)")
I("(MovRM EDX EAX)")                  # index
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
I("(MovRM EDX EAX)")                  # payload|0
I("(OrI8 EDX 01)")                    # restamp as string
I("(MovRMD ECX EAX 04)")              # length fixnum
I("(MovRR EAX EDX)")
emit_call("Cons")
I("(OrI8 EAX 02)")
I("(Ret)")

PL("PrListStr")
I("(MovRM EDX EAX)")                  # char list
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

PL("PrError")
L("(ER 1)")
I("(TestRI8 EAX 03)")
I("(Jnz (ER 2))")
I("(PushR EAX)")
I("(MovRM EAX EAX)")
emit_call("Print")
MOVRI("EAX", 0x20)
emit_call("Emit")
I("(PopR EAX)")
I("(MovRMD EAX EAX 04)")
I("(JmpS (ER 1))")
L("(ER 2)")
MOVRI("EAX", 0x0A)
emit_call("Emit")
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

# ---------------------------------------------------------------------------
# Printer (write-style)
# ---------------------------------------------------------------------------
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
emit_call("Emit")
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
emit_call("Emit")
I("(DecR EBX)")
I("(Jnz (PN 3))")
I("(Ret)")

L("PrintPair")
I("(PushR EAX)")
MOVRI("EAX", 0x28)
emit_call("Emit")
I("(PopR EAX)")
L("(PP 1)")
I("(PushR EAX)")
I("(MovRM EAX EAX)")
emit_call("Print")
I("(PopR EAX)")
I("(MovRMD EAX EAX 04)")
I("(TestRI8 EAX 03)")
I("(Jnz (PP 2))")
I("(PushR EAX)")
MOVRI("EAX", 0x20)
emit_call("Emit")
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
emit_call("Emit")
MOVRI("EAX", 0x2E)
emit_call("Emit")
MOVRI("EAX", 0x20)
emit_call("Emit")
I("(PopR EAX)")
emit_call("Print")
MOVRI("EAX", 0x29)
I("(Jmp32 Emit)")

L("PrintObj")
I("(SubI8 EAX 02)")
I("(MovRM ECX EAX)")                  # payload|sub
I("(MovRMD EDX EAX 04)")
I("(SarI8 EDX 02)")                   # length
I("(MovRR EBX ECX)")
I("(AndI8 EBX 07)")
I("(TestRR EBX EBX)")
I("(Jnz (PO 1))")
I("(Jmp32 PrintRaw)")                 # symbol: raw bytes (ECX clean)
L("(PO 1)")
I("(CmpI8 EBX 01)")
I("(Jz (PO 2))")
MOVRI("EAX", 0x3F)                    # unknown object: ?
I("(Jmp32 Emit)")
L("(PO 2)")
MOVRI("EAX", 0x22)
emit_call("Emit")                     # Emit keeps ECX EDX
I("(AndI8 ECX F8)")
emit_call("PrintRaw")
MOVRI("EAX", 0x22)
I("(Jmp32 Emit)")

L("PrintImm")
CMPEAX(NIL)
I("(Jnz (PI 1))")
MOVRI("EAX", 0x28)
emit_call("Emit")
MOVRI("EAX", 0x29)
I("(Jmp32 Emit)")
L("(PI 1)")
CMPEAX(TRUE)
I("(Jnz (PI 2))")
MOVRI("EAX", 0x23)
emit_call("Emit")
MOVRI("EAX", 0x74)
I("(Jmp32 Emit)")
L("(PI 2)")
CMPEAX(FALSE)
I("(Jnz (PI 3))")
MOVRI("EAX", 0x23)
emit_call("Emit")
MOVRI("EAX", 0x66)
I("(Jmp32 Emit)")
L("(PI 3)")
I("(MovRR ECX EAX)")
I(f"(AndI32 ECX {x8(0xFF)})")
I("(CmpI8 ECX 53)")
I("(Jnz (PI 4))")
I("(PushR EAX)")
MOVRI("EAX", 0x23)
emit_call("Emit")
MOVRI("EAX", 0x5C)
emit_call("Emit")
I("(PopR EAX)")
I("(ShrI8 EAX 08)")
I("(Jmp32 Emit)")
L("(PI 4)")
MOVRI("EAX", 0x3F)                    # eof/unspecified print as ?
I("(Jmp32 Emit)")

# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
I("(Align4)")
for g in (["GCellFree", "GByteFree", "GInPtr", "GInEnd", "GObList", "GEnv",
           "GTokBuf", "GReadBuf"] + [s[0] for s in SPECIALS]):
    L(g)
    init = NIL if g in ("GObList", "GEnv") else 0
    I(f"(Dd {x8(init)})")
L("GPeek")
I(f"(Dd {x8(MINUS1)})")
L("WriteChBuf")
I("(Db 00)")


def string_data(label, text):
    L(label)
    for ch in text.encode():
        I(f"(Db {ch:02X})")


for _, lbl, text in SPECIALS:
    string_data(lbl, text)
for pi, (name, _) in enumerate(PRIMS):
    string_data(f"(LPN {pi})", name)
I("(Align8)")
L("CodeEnd")

# ---------------------------------------------------------------------------
# Emission: chain blocks of instructions into rewrite rules.
# ---------------------------------------------------------------------------
BLOCK = 24


def main():
    print("; scheme0: Stage 2 minimal Scheme interpreter (reader/printer).")
    print("; GENERATED by tools/build_scheme0.py -- edit the builder, then")
    print("; regenerate. The builder is a formatter: instructions appear")
    print("; there 1:1, in order.")
    blocks = [S[i:i + BLOCK] for i in range(0, len(S), BLOCK)]
    for bi, blk in enumerate(blocks):
        print(f"(Rule (Z {bi})")
        for ins in blk:
            print(f"  (Ins {ins}")
        if bi + 1 < len(blocks):
            print(f"  (Z {bi + 1})" + ")" * len(blk) + ")")
        else:
            print("  End" + ")" * len(blk) + ")")
    print()
    print(f"(Assemble (Program Start {x8(0x10000000)} (Z 0)))")


if __name__ == "__main__":
    main()
