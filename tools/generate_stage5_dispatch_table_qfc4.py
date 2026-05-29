#!/usr/bin/env python3
"""Generate the qfc4-lifted Stage 5 multiple-dispatch table fixture."""

from pathlib import Path

from generate_stage5_scan_forwarding_qfc4 import compile_rule, do_expr, qfc4_defs_block


ROOT = Path(__file__).resolve().parents[1]
QFASM_EXT_OUT = ROOT / "bootstrap" / "qfasm-dispatch-ext.qf1"
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-dispatch-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-dispatch-table-qfc4.qf1"


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


def main():
    write_qfasm_extension()
    write_qfc4_extension()
    write_qfc4_source()


if __name__ == "__main__":
    main()
