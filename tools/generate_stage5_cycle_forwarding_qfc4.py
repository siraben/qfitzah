#!/usr/bin/env python3
"""Generate the qfc4-lifted Stage 5 cycle-forwarding fixture."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QFASM_OUT = ROOT / "bootstrap" / "qfasm-stage5-cycle-forwarding-ext.qf1"
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-cycle-forwarding-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-forwarding-cycle-gc-qfc4.qf1"


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
    forward_cycle_root = [
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapAfterCopied)",
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
        "(MovEaxLabel OldRoot)",
        "(MovEbxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 0F)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel Heap)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 0F)",
        "(IfZero UseForwardedCycleCar ForwardCycleUseCar ForwardCycleBadForward)",
    ]

    forward_cycle_use_car = [
        "(PopEax)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
    ]

    check_forwarded_cycle = [
        "(MovEaxLabel OldRoot)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(LoadEbxCarFromEax)",
        "(PopEax)",
        "(CmpEaxEbx)",
        "(IfZero CycleSelfEdgeOk ExitForwardedCycle ForwardCycleBadSelfEdge)",
    ]

    exit_forwarded_cycle = [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(MovEbxEax)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    bad_forward = [
        "(MovEbxImm32 02)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    bad_self_edge = [
        "(MovEbxImm32 01)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    QFASM_OUT.write_text(
        """; Optional qfasm3 expansions for the qfc4 cycle-forwarding fixture.

"""
        + expand_do_rule("ForwardCycleRoot")
        + "\n"
        + expand_do_rule("CheckForwardedCycle")
        + "\n"
        + expand_rule("ForwardCycleRoot", forward_cycle_root)
        + "\n"
        + expand_rule("ForwardCycleUseCar", forward_cycle_use_car)
        + "\n"
        + expand_rule("CheckForwardedCycle", check_forwarded_cycle)
        + "\n"
        + expand_rule("ExitForwardedCycle", exit_forwarded_cycle)
        + "\n"
        + expand_rule("ForwardCycleBadForward", bad_forward)
        + "\n"
        + expand_rule("ForwardCycleBadSelfEdge", bad_self_edge)
    )

    QFC4_EXT_OUT.write_text(
        """; Optional qfc4 cycle-forwarding surface.

(Rule
  (ParseStmt (ForwardCycleRoot))
  ForwardCycleRoot)

(Rule
  (ParseStmt (CheckForwardedCycle))
  CheckForwardedCycle)

(Rule
  (CompileStmt ForwardCycleRoot)
  (Do ForwardCycleRoot End))

(Rule
  (CompileStmt CheckForwardedCycle)
  (Do CheckForwardedCycle End))
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
        "(Data HeapAfterCopied 00",
        "(Data HeapLimit 00",
        "(RawPairPtrVal OldRoot OldRoot 17",
        """(Def
      Start
      NoFrame
      (Seq
        (ForwardCycleRoot)
        (CheckForwardedCycle))""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 cycle-forwarding recovery lifted through qfc4.
;
; Compile with qfc4-cycle-forwarding-ext.qf1,
; qfasm-stage5-cycle-forwarding-ext.qf1, and the Stage 5 heap/scan extensions.
; The source copies one self-referential pair once, records a temporary
; forwarding marker in the old pair, and rewrites the copied self-edge to the
; copied pair.

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


if __name__ == "__main__":
    main()
