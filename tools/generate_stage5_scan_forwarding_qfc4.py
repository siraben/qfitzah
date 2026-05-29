#!/usr/bin/env python3
"""Generate the qfc4-lifted Stage 5 scan-forwarding fixture."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-scan-forwarding-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-scan-forwarding-gc-qfc4.qf1"


def do_block(instrs, base_indent="    "):
    lines = []
    for depth, instr in enumerate(instrs):
        lines.append(f"{base_indent}{'  ' * depth}(Do")
        lines.append(f"{base_indent}{'  ' * (depth + 1)}{instr}")
    lines.append(f"{base_indent}{'  ' * len(instrs)}End" + ")" * len(instrs))
    return "\n".join(lines)


def do_expr(instrs):
    expr = "End"
    for instr in reversed(instrs):
        expr = f"(Do {instr} {expr})"
    return expr


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


def compile_rule(name, instrs):
    return f"""(Rule
  (CompileStmt {name})
{do_block(instrs, "  ")})
"""


def qfc4_defs_block(defs):
    lines = []
    for form in defs:
        lines.append(f"    {form}")
    lines.append("    End" + ")" * len(defs))
    return "\n".join(lines)


def scan_car():
    return [
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(TestAlPair)",
        "(IfZero HandleCarPair "
        + do_expr(
            [
                "(PopEax)",
                "(PushEax)",
                "(LoadEaxCdr)",
                "(CmpEaxImm8 0F)",
                "(IfZero UseForwardedCar "
                + do_expr(scan_use_car())
                + " "
                + do_expr(scan_copy_car())
                + ")",
            ]
        )
        + " (Do (PopEax) (Do (Ret) End)))",
    ]


def without_ret(instrs):
    return [instr for instr in instrs if instr != "(Ret)"]


def scan_car_inline():
    return [
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(TestAlPair)",
        "(IfZero HandleCarPair "
        + do_expr(
            [
                "(PopEax)",
                "(PushEax)",
                "(LoadEaxCdr)",
                "(CmpEaxImm8 0F)",
                "(IfZero UseForwardedCar "
                + do_expr(without_ret(scan_use_car()))
                + " "
                + do_expr(without_ret(scan_copy_car()))
                + ")",
            ]
        )
        + " (Do (PopEax) End))",
    ]


def scan_copy_car():
    return [
        "(PopEax)",
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
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxFromEbx)",
        "(AddEbxImm8 08)",
        "(MovEaxLabel HeapNext)",
        "(StoreDwordAtEaxFromEbx)",
        "(Ret)",
    ]


def scan_use_car():
    return [
        "(PopEax)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxFromEbx)",
        "(Ret)",
    ]


def scan_cdr():
    return [
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(PushEax)",
        "(TestAlPair)",
        "(IfZero HandleCdrPair "
        + do_expr(
            [
                "(PopEax)",
                "(PushEax)",
                "(LoadEaxCdr)",
                "(CmpEaxImm8 0F)",
                "(IfZero UseForwardedCdr "
                + do_expr(scan_use_cdr())
                + " "
                + do_expr(scan_copy_cdr())
                + ")",
            ]
        )
        + " (Do (PopEax) (Do (Ret) End)))",
    ]


def scan_copy_cdr():
    return [
        "(PopEax)",
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
        "(MovEcxEbx)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(AddEbxImm8 08)",
        "(MovEaxLabel HeapNext)",
        "(StoreDwordAtEaxFromEbx)",
        "(Ret)",
    ]


def scan_use_cdr():
    return [
        "(PopEax)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEcxEbx)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(Ret)",
    ]


def init_scan_forwarding():
    return [
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapChild)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel Scan)",
        "(MovEbxLabel Heap)",
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
    ]


def check_scan_forwarding():
    return [
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
        "(IfZero FieldsShared "
        + do_expr(check_child_cycle())
        + " "
        + do_expr(bad_status("01"))
        + ")",
    ]


def check_child_cycle():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(LoadEaxCdr)",
        "(PopEbx)",
        "(CmpEaxEbx)",
        "(IfZero ChildCycleOk "
        + do_expr(check_heap_next())
        + " "
        + do_expr(bad_status("02"))
        + ")",
    ]


def check_heap_next():
    return [
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterCopied)",
        "(CmpEaxEbx)",
        "(IfZero HeapNextOk "
        + do_expr(exit_copied_child())
        + " "
        + do_expr(bad_status("03"))
        + ")",
    ]


def exit_copied_child():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEbxCarFromEax)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def bad_status(value):
    return [
        f"(MovEbxImm32 {value})",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def main():
    names = [
        "InitScanForwarding",
        "ScanForwardCarInline",
        "ScanForwardCdr",
        "CheckScanForwarding",
    ]

    qfc4 = ["; Optional qfc4 scan-forwarding surface.\n\n"]
    for name in names:
        qfc4.append(f"""(Rule
  (ParseStmt ({name}))
  {name})

""")
    for name, instrs in [
        ("InitScanForwarding", init_scan_forwarding()),
        ("ScanForwardCarInline", scan_car_inline()),
        ("ScanForwardCdr", scan_cdr()),
        ("CheckScanForwarding", check_scan_forwarding()),
    ]:
        qfc4.append(compile_rule(name, instrs))
        qfc4.append("\n")
    QFC4_EXT_OUT.write_text("".join(qfc4).rstrip() + "\n")

    defs = [
        "(PtrCell HeapNext HeapLimit",
        "(PtrCell Scan Heap",
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
        "(RawPairValPtr OldShared 13 OldShared",
        """(Def
      ScanCdr
      NoFrame
      (ScanForwardCdr)""",
        """(Def
      Start
      NoFrame
      (Seq
        (InitScanForwarding)
        (Seq
          (Local ScanLoop)
          (Seq
            (CallProc ScanCdr)
            (Seq
              (ScanForwardCarInline)
              (Seq
                (AdvanceScanOrLoop ScanLoop)
                (CheckScanForwarding))))))""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 scan-forwarding recovery lifted through qfc4.
;
; Compile with qfc4-scan-forwarding-ext.qf1 and the Stage 5 heap/scan
; extensions. The source keeps the scan loop readable while the optional qfc4
; extension owns the long forwarding field handlers.

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


if __name__ == "__main__":
    main()
