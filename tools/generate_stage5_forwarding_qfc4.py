#!/usr/bin/env python3
"""Generate the qfc4-lifted Stage 5 forwarding-pointer fixtures."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QFASM_OUT = ROOT / "bootstrap" / "qfasm-stage5-forwarding-ext.qf1"
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-forwarding-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-forwarding-gc-qfc4.qf1"


def do_block(instrs, base_indent="    "):
    lines = []
    for depth, instr in enumerate(instrs):
        lines.append(f"{base_indent}{'  ' * depth}(Do")
        lines.append(f"{base_indent}{'  ' * (depth + 1)}{instr}")
    lines.append(f"{base_indent}{'  ' * len(instrs)}End" + ")" * len(instrs))
    return "\n".join(lines)


def expand_rule(name, instrs):
    return f"""(Rule
  (Expand {name} scope)
  (Expand
{do_block(instrs, "    ")}
    scope))
"""


def expand_do_rule(name):
    return f"""(Rule
  (Expand (Do {name} rest) scope)
  (Append (Expand {name} scope) (Expand rest scope)))
"""


def qfc4_defs_block(defs):
    lines = []
    for form in defs:
        lines.append(f"    {form}")
    lines.append("    End" + ")" * len(defs))
    return "\n".join(lines)


def main():
    forward_shared_root = [
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapChild)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEbxCarFromEax)",
        "(LoadEcxCdrFromEax)",
        "(MovEaxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel Root)",
        "(MovEbxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel Heap)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(LoadEbxCarFromEax)",
        "(LoadEcxCdrFromEax)",
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxFromEbx)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEbxEax)",
        "(PopEax)",
        "(PushEbx)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 0F)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(PopEbx)",
        "(MovEaxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(AddEbxImm8 08)",
        "(MovEaxLabel HeapNext)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel Heap)",
        "(LoadEaxCdr)",
        "(PushEax)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 0F)",
        "(IfZero UseForwardedCdr ForwardSharedUseCdr ForwardSharedBadCdr)",
    ]

    forward_shared_use_cdr = [
        "(PopEax)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEcxEbx)",
        "(MovEaxLabel Heap)",
        "(StoreDwordAtEaxPlus4FromEcx)",
    ]

    forward_shared_bad_cdr = [
        "(MovEbxImm32 02)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    check_forwarded_shared = [
        "(MovEaxLabel OldShared)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(CmpEaxEbx)",
        "(IfZero FieldsShared CheckHeapNext ForwardSharedBadFields)",
    ]

    check_heap_next = [
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterCopied)",
        "(CmpEaxEbx)",
        "(IfZero HeapNextOk CheckCopiedChild ForwardSharedBadHeapNext)",
    ]

    check_copied_child = [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEbxCarFromEax)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    bad_fields = [
        "(MovEbxImm32 01)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    bad_heap_next = [
        "(MovEbxImm32 02)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    QFASM_OUT.write_text(
        """; Optional qfasm3 expansions for the qfc4 forwarding-pointer fixture.

"""
        + expand_do_rule("ForwardSharedRoot")
        + "\n"
        + expand_do_rule("CheckForwardedShared")
        + "\n"
        + expand_rule("ForwardSharedRoot", forward_shared_root)
        + "\n"
        + expand_rule("ForwardSharedUseCdr", forward_shared_use_cdr)
        + "\n"
        + expand_rule("ForwardSharedBadCdr", forward_shared_bad_cdr)
        + "\n"
        + expand_rule("CheckForwardedShared", check_forwarded_shared)
        + "\n"
        + expand_rule("CheckHeapNext", check_heap_next)
        + "\n"
        + expand_rule("CheckCopiedChild", check_copied_child)
        + "\n"
        + expand_rule("ForwardSharedBadFields", bad_fields)
        + "\n"
        + expand_rule("ForwardSharedBadHeapNext", bad_heap_next)
    )

    QFC4_EXT_OUT.write_text(
        """; Optional qfc4 forwarding-pointer surface.

(Rule
  (ParseStmt (ForwardSharedRoot))
  ForwardSharedRoot)

(Rule
  (ParseStmt (CheckForwardedShared))
  CheckForwardedShared)

(Rule
  (CompileStmt ForwardSharedRoot)
  (Do ForwardSharedRoot End))

(Rule
  (CompileStmt CheckForwardedShared)
  (Do CheckForwardedShared End))
"""
    )

    defs = [
        "(PtrCell HeapNext HeapLimit",
        "(PtrCell Root OldRoot",
        "(Data Heap 00",
        "(Data Heap1 00",
        "(Data Heap2 00",
        "(Data Heap3 00",
        "(Data Heap4 00",
        "(Data Heap5 00",
        "(Data Heap6 00",
        "(Data Heap7 00",
        "(Data HeapChild 00",
        "(Data HeapChild1 00",
        "(Data HeapChild2 00",
        "(Data HeapChild3 00",
        "(Data HeapChild4 00",
        "(Data HeapChild5 00",
        "(Data HeapChild6 00",
        "(Data HeapChild7 00",
        "(Data HeapAfterCopied 00",
        "(Data HeapLimit 00",
        "(RawPairPtrs OldRoot OldShared OldShared",
        "(RawPair OldShared 13 01",
        """(Def
      Start
      NoFrame
      (Seq
        (ForwardSharedRoot)
        (CheckForwardedShared))""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 forwarding-pointer recovery lifted through qfc4.
;
; Compile with qfc4-forwarding-ext.qf1, qfasm-stage5-forwarding-ext.qf1, and
; the Stage 5 heap/scan extensions. The source preserves a shared pair by
; copying it once, recording a temporary forwarding marker in the old pair, and
; rewriting both copied root fields to the single copied child.

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


if __name__ == "__main__":
    main()
