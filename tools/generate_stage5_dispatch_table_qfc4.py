#!/usr/bin/env python3
"""Generate the qfc4-lifted Stage 5 multiple-dispatch table fixture."""

from pathlib import Path

from generate_stage5_scan_forwarding_qfc4 import compile_rule, do_block, do_expr, qfc4_defs_block


ROOT = Path(__file__).resolve().parents[1]
QFASM_EXT_OUT = ROOT / "bootstrap" / "qfasm-dispatch-ext.qf1"
QFASM_RUNTIME_EXT_OUT = ROOT / "bootstrap" / "qfasm-dispatch-runtime-ext.qf1"
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-dispatch-ext.qf1"
QFC4_CHAIN_EXT_OUT = ROOT / "bootstrap" / "qfc4-dispatch-chain-ext.qf1"
QFC4_RUNTIME_CHAIN_EXT_OUT = ROOT / "bootstrap" / "qfc4-dispatch-runtime-chain-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-dispatch-table-qfc4.qf1"
QFC4_CHAIN_SRC_OUT = ROOT / "bootstrap" / "stage5-dispatch-chain-qfc4.qf1"
QFC4_CHAIN_MISS_SRC_OUT = ROOT / "bootstrap" / "stage5-dispatch-chain-miss-qfc4.qf1"
QFC4_RUNTIME_CHAIN_SRC_OUT = ROOT / "bootstrap" / "stage5-dispatch-runtime-chain-qfc4.qf1"
QFC4_MUTABLE_RUNTIME_CHAIN_SRC_OUT = (
    ROOT / "bootstrap" / "stage5-dispatch-mutable-runtime-chain-qfc4.qf1"
)
QFC4_MUTABLE_METHOD_CHAIN_SRC_OUT = (
    ROOT / "bootstrap" / "stage5-dispatch-mutable-method-chain-qfc4.qf1"
)


def bad_status(value):
    return [
        f"(MovEbxImm32 {value})",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def dispatch_entry(entry, arg1, arg2, next_label, final=False):
    miss = bad_status("09") if final else []
    return [
        f"(MovEaxLabel {entry})",
        "(PushEax)",
        "(LoadEaxCar)",
        "(LoadEbxCarFromEax)",
        f"(CmpEbxImm8 {arg1})",
        f"(Jnz {next_label})",
        "(LoadEaxCdr)",
        f"(CmpEaxImm8 {arg2})",
        f"(Jnz {next_label})",
        "(PopEax)",
        "(LoadEaxCdr)",
        "(CallEax)",
        "(Jump DispatchDone)",
        f"(Label {next_label})",
        "(PopEax)",
        *miss,
    ]


def dispatch_two_entries():
    return [
        *dispatch_entry("EntryWrong", "13", "2A", "TryEntryHit"),
        *dispatch_entry("EntryHit", "13", "2A", "DispatchMiss", final=True),
        "(Label DispatchDone)",
    ]


def method_wrong():
    return [
        "(MovEbxImm32 07)",
        "(Ret)",
    ]


def method_hit():
    return [
        "(MovEbxImm32 2A)",
        "(Ret)",
    ]


def dispatch_chain():
    return [
        "(MovEaxLabel EntryMissArg1)",
        "(Label DispatchLoop)",
        "(CmpEaxLabel NoEntry)",
        "(Jz DispatchMiss)",
        "(PushEax)",
        "(LoadEaxCar)",
        "(LoadEbxCarFromEax)",
        "(CmpEbxImm8 13)",
        "(Jnz DispatchAdvance)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 2A)",
        "(Jnz DispatchAdvance)",
        "(PopEax)",
        "(LoadEaxCdr)",
        "(LoadEaxCar)",
        "(CallEax)",
        "(Jump DispatchDone)",
        "(Label DispatchAdvance)",
        "(PopEax)",
        "(LoadEaxCdr)",
        "(LoadEaxCdr)",
        "(Jump DispatchLoop)",
        "(Label DispatchMiss)",
        *bad_status("09"),
        "(Label DispatchDone)",
    ]


def runtime_dispatch_chain():
    return [
        "(MovEaxLabel Arg1Class)",
        "(LoadEaxCar)",
        "(MovEcxEax)",
        "(MovEaxLabel Arg2Class)",
        "(LoadEaxCar)",
        "(MovEdxEax)",
        "(MovEaxLabel EntryMissArg1)",
        "(Label DispatchLoop)",
        "(CmpEaxLabel NoEntry)",
        "(Jz DispatchMiss)",
        "(PushEax)",
        "(LoadEaxCar)",
        "(LoadEbxCarFromEax)",
        "(CmpEbxEcx)",
        "(Jnz DispatchAdvance)",
        "(LoadEaxCdr)",
        "(CmpEaxEdx)",
        "(Jnz DispatchAdvance)",
        "(PopEax)",
        "(LoadEaxCdr)",
        "(LoadEaxCar)",
        "(CallEax)",
        "(Jump DispatchDone)",
        "(Label DispatchAdvance)",
        "(PopEax)",
        "(LoadEaxCdr)",
        "(LoadEaxCdr)",
        "(Jump DispatchLoop)",
        "(Label DispatchMiss)",
        *bad_status("09"),
        "(Label DispatchDone)",
    ]


def set_arg2_class(value):
    return [
        "(MovEaxLabel Arg2Class)",
        f"(MovEbxImm32 {value})",
        "(StoreDwordAtEaxFromEbx)",
    ]


def set_entry_method(payload, method):
    return [
        f"(MovEaxLabel {payload})",
        f"(MovEbxLabel {method})",
        "(StoreDwordAtEaxFromEbx)",
    ]


def method_wrong_a():
    return [
        "(MovEbxImm32 07)",
        "(Ret)",
    ]


def method_wrong_b():
    return [
        "(MovEbxImm32 08)",
        "(Ret)",
    ]


def method_hit_chain():
    return [
        "(MovEbxImm32 2A)",
        "(Ret)",
    ]


def write_qfasm_extension():
    QFASM_EXT_OUT.write_text(
        """; Optional qfasm2/qfasm3 support for dispatch-table fixtures.

(Rule
  (Size (CallEax))
  N2)

(Rule
  (Pass2 (Ins (CallEax) rest) pc sym)
  (Bytes FF D0 (Pass2 rest (Add pc N2) sym)))

(Rule
  (Expand (Do (CallEax) rest) scope)
  (Ins (CallEax) (Expand rest scope)))

(Rule
  (Expand (Do (Jnz name) rest) scope)
  (Ins (Jnz name) (Expand rest scope)))

(Rule
  (Expand (Do (Jz name) rest) scope)
  (Ins (Jz name) (Expand rest scope)))

(Rule
  (Expand (Do (Jump name) rest) scope)
  (Ins (Jump name) (Expand rest scope)))
"""
    )


def write_qfasm_runtime_extension():
    QFASM_RUNTIME_EXT_OUT.write_text(
        """; Optional qfasm2/qfasm3 support for runtime-argument dispatch fixtures.
;
; Runtime dispatch fixtures can rewrite argument-class cells, so their ELF
; segment is writable as well as executable.

(Rule
  (ElfHeader entry size)
  (Bytes
    7F 45 4C 46 01 01 01 00 00 00 00 00 00 00 00 00
    02 00 03 00 01 00 00 00 (Addr entry) 34 00 00 00
    00 00 00 00 00 00 00 00 34 00 20 00 01 00 00 00
    00 00 00 00 01 00 00 00 00 00 00 00 00 80 04 08
    00 80 04 08 (FileSize size) (FileSize size) 07 00 00 00
    00 10 00 00))

(Rule
  (Size (CallEax))
  N2)

(Rule
  (Size (MovEcxEax))
  N2)

(Rule
  (Size (MovEdxEax))
  N2)

(Rule
  (Size (CmpEbxEcx))
  N2)

(Rule
  (Size (CmpEaxEdx))
  N2)

(Rule
  (Size (StoreDwordAtEaxFromEbx))
  N2)

(Rule
  (Pass2 (Ins (CallEax) rest) pc sym)
  (Bytes FF D0 (Pass2 rest (Add pc N2) sym)))

(Rule
  (Pass2 (Ins (MovEcxEax) rest) pc sym)
  (Bytes 89 C1 (Pass2 rest (Add pc N2) sym)))

(Rule
  (Pass2 (Ins (MovEdxEax) rest) pc sym)
  (Bytes 89 C2 (Pass2 rest (Add pc N2) sym)))

(Rule
  (Pass2 (Ins (CmpEbxEcx) rest) pc sym)
  (Bytes 39 CB (Pass2 rest (Add pc N2) sym)))

(Rule
  (Pass2 (Ins (CmpEaxEdx) rest) pc sym)
  (Bytes 39 D0 (Pass2 rest (Add pc N2) sym)))

(Rule
  (Pass2 (Ins (StoreDwordAtEaxFromEbx) rest) pc sym)
  (Bytes 89 18 (Pass2 rest (Add pc N2) sym)))

(Rule
  (Expand (Do (CallEax) rest) scope)
  (Ins (CallEax) (Expand rest scope)))

(Rule
  (Expand (Do (MovEcxEax) rest) scope)
  (Ins (MovEcxEax) (Expand rest scope)))

(Rule
  (Expand (Do (MovEdxEax) rest) scope)
  (Ins (MovEdxEax) (Expand rest scope)))

(Rule
  (Expand (Do (CmpEbxEcx) rest) scope)
  (Ins (CmpEbxEcx) (Expand rest scope)))

(Rule
  (Expand (Do (CmpEaxEdx) rest) scope)
  (Ins (CmpEaxEdx) (Expand rest scope)))

(Rule
  (Expand (Do (StoreDwordAtEaxFromEbx) rest) scope)
  (Ins (StoreDwordAtEaxFromEbx) (Expand rest scope)))

(Rule
  (Expand (Do (Jnz name) rest) scope)
  (Ins (Jnz name) (Expand rest scope)))

(Rule
  (Expand (Do (Jz name) rest) scope)
  (Ins (Jz name) (Expand rest scope)))

(Rule
  (Expand (Do (Jump name) rest) scope)
  (Ins (Jump name) (Expand rest scope)))
"""
    )


def write_qfc4_extension():
    parts = [
        """; Optional qfc4 surface for a two-argument dispatch table.

(Rule
  (ParseDefs (DispatchEntry name sig arg1 arg2 method rest))
  (AstDispatchEntry name sig arg1 arg2 method (ParseDefs rest)))

(Rule
  (CompileDefs (AstDispatchEntry name sig arg1 arg2 method rest))
  (DAppend (CompileDispatchEntry name sig arg1 arg2 method) (CompileDefs rest)))

(Rule
  (CompileDispatchEntry name sig arg1 arg2 method)
  (Do
    (Align4)
    (Do
      (Label sig)
      (Do
        (Dword arg1)
        (Do
          (Dword arg2)
          (Do
            (Align4)
            (Do
              (Label name)
              (Do (DwordLabel sig) (Do (DwordLabel method) End)))))))))

(Rule
  (ParseStmt (DispatchTwoEntries))
  DispatchTwoEntries)

(Rule
  (ParseStmt (MethodWrong))
  MethodWrong)

(Rule
  (ParseStmt (MethodHit))
  MethodHit)

"""
    ]

    for name, instrs in [
        ("DispatchTwoEntries", dispatch_two_entries()),
        ("MethodWrong", method_wrong()),
        ("MethodHit", method_hit()),
    ]:
        parts.append(compile_rule(name, instrs))
        parts.append("\n")

    QFC4_EXT_OUT.write_text("".join(parts).rstrip() + "\n")


def write_qfc4_chain_extension():
    parts = [
        """; Optional qfc4 surface for a looped two-argument dispatch chain.

(Rule
  (ParseDefs (DispatchChainEntry name sig payload arg1 arg2 method next rest))
  (AstDispatchChainEntry name sig payload arg1 arg2 method next (ParseDefs rest)))

(Rule
  (CompileDefs (AstDispatchChainEntry name sig payload arg1 arg2 method next rest))
  (DAppend (CompileDispatchChainEntry name sig payload arg1 arg2 method next) (CompileDefs rest)))

(Rule
  (CompileDispatchChainEntry name sig payload arg1 arg2 method next)
  (Do
    (Align4)
    (Do
      (Label sig)
      (Do
        (Dword arg1)
        (Do
          (Dword arg2)
          (Do
            (Align4)
            (Do
              (Label payload)
              (Do
                (DwordLabel method)
                (Do
                  (DwordLabel next)
                  (Do
                    (Align4)
                    (Do
                      (Label name)
                      (Do (DwordLabel sig) (Do (DwordLabel payload) End)))))))))))))

(Rule
  (ParseDefs (DispatchEnd name rest))
  (AstDispatchEnd name (ParseDefs rest)))

(Rule
  (CompileDefs (AstDispatchEnd name rest))
  (DAppend (CompileDispatchEnd name) (CompileDefs rest)))

(Rule
  (CompileDispatchEnd name)
  (Do
    (Align4)
    (Do (Label name) (Do (Dword 00) End))))

(Rule
  (ParseStmt (DispatchChain))
  DispatchChain)

(Rule
  (ParseStmt (MethodWrongA))
  MethodWrongA)

(Rule
  (ParseStmt (MethodWrongB))
  MethodWrongB)

(Rule
  (ParseStmt (MethodHitChain))
  MethodHitChain)

"""
    ]

    for name, instrs in [
        ("DispatchChain", dispatch_chain()),
        ("MethodWrongA", method_wrong_a()),
        ("MethodWrongB", method_wrong_b()),
        ("MethodHitChain", method_hit_chain()),
    ]:
        parts.append(compile_rule(name, instrs))
        parts.append("\n")

    QFC4_CHAIN_EXT_OUT.write_text("".join(parts).rstrip() + "\n")


def write_qfc4_runtime_chain_extension():
    parts = [
        """; Optional qfc4 surface for runtime-argument two-argument dispatch.

(Rule
  (ParseDefs (DispatchChainEntry name sig payload arg1 arg2 method next rest))
  (AstDispatchChainEntry name sig payload arg1 arg2 method next (ParseDefs rest)))

(Rule
  (CompileDefs (AstDispatchChainEntry name sig payload arg1 arg2 method next rest))
  (DAppend (CompileDispatchChainEntry name sig payload arg1 arg2 method next) (CompileDefs rest)))

(Rule
  (CompileDispatchChainEntry name sig payload arg1 arg2 method next)
  (Do
    (Align4)
    (Do
      (Label sig)
      (Do
        (Dword arg1)
        (Do
          (Dword arg2)
          (Do
            (Align4)
            (Do
              (Label payload)
              (Do
                (DwordLabel method)
                (Do
                  (DwordLabel next)
                  (Do
                    (Align4)
                    (Do
                      (Label name)
                      (Do (DwordLabel sig) (Do (DwordLabel payload) End)))))))))))))

(Rule
  (ParseDefs (DispatchEnd name rest))
  (AstDispatchEnd name (ParseDefs rest)))

(Rule
  (CompileDefs (AstDispatchEnd name rest))
  (DAppend (CompileDispatchEnd name) (CompileDefs rest)))

(Rule
  (CompileDispatchEnd name)
  (Do
    (Align4)
    (Do (Label name) (Do (Dword 00) End))))

(Rule
  (ParseDefs (DispatchArgClass name value rest))
  (AstDispatchArgClass name value (ParseDefs rest)))

(Rule
  (CompileDefs (AstDispatchArgClass name value rest))
  (DAppend (CompileDispatchArgClass name value) (CompileDefs rest)))

(Rule
  (CompileDispatchArgClass name value)
  (Do
    (Align4)
    (Do (Label name) (Do (Dword value) End))))

(Rule
  (ParseStmt (RuntimeDispatchChain))
  RuntimeDispatchChain)

(Rule
  (ParseStmt (SetArg2Class value))
  (SetArg2Class value))

(Rule
  (ParseStmt (SetEntryMethod payload method))
  (SetEntryMethod payload method))

(Rule
  (ParseStmt (MethodWrongA))
  MethodWrongA)

(Rule
  (ParseStmt (MethodWrongB))
  MethodWrongB)

(Rule
  (ParseStmt (MethodHitChain))
  MethodHitChain)

"""
    ]

    for name, instrs in [
        ("RuntimeDispatchChain", runtime_dispatch_chain()),
        ("MethodWrongA", method_wrong_a()),
        ("MethodWrongB", method_wrong_b()),
        ("MethodHitChain", method_hit_chain()),
    ]:
        parts.append(compile_rule(name, instrs))
        parts.append("\n")

    parts.append("""(Rule
  (CompileStmt (SetArg2Class value))
""")
    parts.append(do_block(set_arg2_class("value"), "  "))
    parts.append(")\n")

    parts.append("""(Rule
  (CompileStmt (SetEntryMethod payload method))
""")
    parts.append(do_block(set_entry_method("payload", "method"), "  "))
    parts.append(")\n")

    QFC4_RUNTIME_CHAIN_EXT_OUT.write_text("".join(parts).rstrip() + "\n")


def write_qfc4_source():
    defs = [
        "(DispatchEntry EntryWrong SigWrong 13 23 MethodWrong",
        "(DispatchEntry EntryHit SigHit 13 2A MethodHit",
        """(Def
      Start
      NoFrame
      (Seq
        (DispatchTwoEntries)
        (ExitReg Ebx))""",
        """(Def
      MethodWrong
      NoFrame
      (MethodWrong)""",
        """(Def
      MethodHit
      NoFrame
      (MethodHit)""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 multiple-dispatch table fixture lifted through qfc4.
;
; The qfc4 source compiles two dispatch entries. Each entry contains a
; two-argument signature record plus a concrete method code pointer. Runtime
; dispatch checks both signature fields, skips the first non-matching entry,
; loads the matching method pointer from the table, calls it indirectly, and
; exits with the method result (`42`).

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


def write_qfc4_chain_source():
    defs = [
        "(DispatchChainEntry EntryMissArg1 SigMissArg1 PayloadMissArg1 12 2A MethodWrongA EntryMissArg2",
        "(DispatchChainEntry EntryMissArg2 SigMissArg2 PayloadMissArg2 13 23 MethodWrongB EntryHitChain",
        "(DispatchChainEntry EntryHitChain SigHitChain PayloadHitChain 13 2A MethodHitChain NoEntry",
        "(DispatchEnd NoEntry",
        """(Def
      Start
      NoFrame
      (Seq
        (DispatchChain)
        (ExitReg Ebx))""",
        """(Def
      MethodWrongA
      NoFrame
      (MethodWrongA)""",
        """(Def
      MethodWrongB
      NoFrame
      (MethodWrongB)""",
        """(Def
      MethodHitChain
      NoFrame
      (MethodHitChain)""",
    ]

    QFC4_CHAIN_SRC_OUT.write_text(
        """; Stage 5 looped multiple-dispatch chain fixture lifted through qfc4.
;
; The qfc4 source compiles a linked dispatch table. Each entry stores a
; two-argument signature, a method pointer, and a next-entry pointer. Runtime
; dispatch loops over the chain, skips an arg1 miss and then an arg2 miss,
; loads the first matching method pointer, calls it indirectly, and exits with
; the selected method result (`42`).

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


def write_qfc4_chain_miss_source():
    defs = [
        "(DispatchChainEntry EntryMissArg1 SigMissArg1 PayloadMissArg1 12 2A MethodWrongA EntryMissArg2",
        "(DispatchChainEntry EntryMissArg2 SigMissArg2 PayloadMissArg2 13 23 MethodWrongB NoEntry",
        "(DispatchEnd NoEntry",
        """(Def
      Start
      NoFrame
      (Seq
        (DispatchChain)
        (ExitReg Ebx))""",
        """(Def
      MethodWrongA
      NoFrame
      (MethodWrongA)""",
        """(Def
      MethodWrongB
      NoFrame
      (MethodWrongB)""",
        """(Def
      MethodHitChain
      NoFrame
      (MethodHitChain)""",
    ]

    QFC4_CHAIN_MISS_SRC_OUT.write_text(
        """; Stage 5 looped multiple-dispatch miss fixture lifted through qfc4.
;
; The qfc4 source compiles a linked dispatch table with no matching method.
; Runtime dispatch skips an arg1 miss and then an arg2 miss, reaches the
; end-of-chain sentinel, and exits through the dispatch-miss path (`9`).

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


def write_qfc4_runtime_chain_source():
    defs = [
        "(DispatchArgClass Arg1Class 13",
        "(DispatchArgClass Arg2Class 2A",
        "(DispatchChainEntry EntryMissArg1 SigMissArg1 PayloadMissArg1 12 2A MethodWrongA EntryMissArg2",
        "(DispatchChainEntry EntryMissArg2 SigMissArg2 PayloadMissArg2 13 23 MethodWrongB EntryHitChain",
        "(DispatchChainEntry EntryHitChain SigHitChain PayloadHitChain 13 2A MethodHitChain NoEntry",
        "(DispatchEnd NoEntry",
        """(Def
      Start
      NoFrame
      (Seq
        (RuntimeDispatchChain)
        (ExitReg Ebx))""",
        """(Def
      MethodWrongA
      NoFrame
      (MethodWrongA)""",
        """(Def
      MethodWrongB
      NoFrame
      (MethodWrongB)""",
        """(Def
      MethodHitChain
      NoFrame
      (MethodHitChain)""",
    ]

    QFC4_RUNTIME_CHAIN_SRC_OUT.write_text(
        """; Stage 5 runtime-argument multiple-dispatch chain fixture lifted through qfc4.
;
; The qfc4 source compiles runtime argument class cells plus a linked dispatch
; table. Runtime dispatch loads the two actual class values from data records,
; compares table signatures against those values, skips arg1 and arg2 misses,
; indirectly calls the matching method, and exits with the selected method
; result (`42`).

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


def write_qfc4_mutable_runtime_chain_source():
    defs = [
        "(DispatchArgClass Arg1Class 13",
        "(DispatchArgClass Arg2Class 2A",
        "(DispatchChainEntry EntryMissArg1 SigMissArg1 PayloadMissArg1 12 2A MethodWrongA EntryAltArg2",
        "(DispatchChainEntry EntryAltArg2 SigAltArg2 PayloadAltArg2 13 23 MethodWrongB EntryHitChain",
        "(DispatchChainEntry EntryHitChain SigHitChain PayloadHitChain 13 2A MethodHitChain NoEntry",
        "(DispatchEnd NoEntry",
        """(Def
      Start
      NoFrame
      (Seq
        (SetArg2Class 23)
        (Seq
          (RuntimeDispatchChain)
          (ExitReg Ebx)))""",
        """(Def
      MethodWrongA
      NoFrame
      (MethodWrongA)""",
        """(Def
      MethodWrongB
      NoFrame
      (MethodWrongB)""",
        """(Def
      MethodHitChain
      NoFrame
      (MethodHitChain)""",
    ]

    QFC4_MUTABLE_RUNTIME_CHAIN_SRC_OUT.write_text(
        """; Stage 5 mutable runtime-argument dispatch chain fixture lifted through qfc4.
;
; The qfc4 source compiles runtime argument class cells plus a linked dispatch
; table, then rewrites the second argument class before dispatch. Runtime
; dispatch must observe the mutated class value and call the alternate method
; for signature `(13 23)`, exiting with status `8`; a stale hardcoded `(13 2A)`
; lookup would call the later method and exit `42`.

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


def write_qfc4_mutable_method_chain_source():
    defs = [
        "(DispatchArgClass Arg1Class 13",
        "(DispatchArgClass Arg2Class 2A",
        "(DispatchChainEntry EntryMissArg1 SigMissArg1 PayloadMissArg1 12 2A MethodWrongA EntryAltArg2",
        "(DispatchChainEntry EntryAltArg2 SigAltArg2 PayloadAltArg2 13 23 MethodWrongB EntryStaleArg2",
        "(DispatchChainEntry EntryStaleArg2 SigStaleArg2 PayloadStaleArg2 13 2A MethodWrongA NoEntry",
        "(DispatchEnd NoEntry",
        """(Def
      Start
      NoFrame
      (Seq
        (SetArg2Class 23)
        (Seq
          (SetEntryMethod PayloadAltArg2 MethodHitChain)
          (Seq
            (RuntimeDispatchChain)
            (ExitReg Ebx))))""",
        """(Def
      MethodWrongA
      NoFrame
      (MethodWrongA)""",
        """(Def
      MethodWrongB
      NoFrame
      (MethodWrongB)""",
        """(Def
      MethodHitChain
      NoFrame
      (MethodHitChain)""",
    ]

    QFC4_MUTABLE_METHOD_CHAIN_SRC_OUT.write_text(
        """; Stage 5 mutable dispatch-method fixture lifted through qfc4.
;
; The qfc4 source rewrites both the second argument class and the selected
; table entry's method pointer before dispatch. The generated ELF exits `42`
; only if dispatch observes both mutations: ignoring the class-cell update
; selects the stale `(13 2A)` entry and exits `7`, while ignoring the method
; pointer update selects the `(13 23)` entry's old method and exits `8`.

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


def main():
    write_qfasm_extension()
    write_qfasm_runtime_extension()
    write_qfc4_extension()
    write_qfc4_chain_extension()
    write_qfc4_runtime_chain_extension()
    write_qfc4_source()
    write_qfc4_chain_source()
    write_qfc4_chain_miss_source()
    write_qfc4_runtime_chain_source()
    write_qfc4_mutable_runtime_chain_source()
    write_qfc4_mutable_method_chain_source()


if __name__ == "__main__":
    main()
