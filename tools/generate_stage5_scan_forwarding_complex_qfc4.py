#!/usr/bin/env python3
"""Generate the qfc4-lifted complex Stage 5 scan-forwarding fixture."""

from pathlib import Path

from generate_stage5_scan_forwarding_qfc4 import (
    compile_rule,
    do_expr,
    qfc4_defs_block,
    scan_car_inline,
    scan_cdr,
)


ROOT = Path(__file__).resolve().parents[1]
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-scan-forwarding-complex-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-scan-forwarding-complex-gc-qfc4.qf1"


def init_scan_forwarding_complex():
    return [
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapLeft)",
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


def check_scan_forwarding_complex():
    return [
        "(MovEaxLabel OldLeft)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel OldRight)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel OldShared)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(PushEax)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(LoadEaxCar)",
        "(PopEbx)",
        "(CmpEaxEbx)",
        "(IfZero SharedPathsMeet "
        + do_expr(check_shared_cycle())
        + " "
        + do_expr(bad_status("01"))
        + ")",
    ]


def check_shared_cycle():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(PushEax)",
        "(LoadEaxCdr)",
        "(PopEbx)",
        "(CmpEaxEbx)",
        "(IfZero SharedCycleOk "
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
        + do_expr(exit_copied_shared())
        + " "
        + do_expr(bad_status("03"))
        + ")",
    ]


def exit_copied_shared():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
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


def data_cell(label):
    return [f"(Data {label} 00"] + [f"(Data {label}{n} 00" for n in range(1, 8)]


def main():
    names = [
        "InitScanForwardingComplex",
        "ScanForwardCarInline",
        "ScanForwardCdr",
        "CheckScanForwardingComplex",
    ]

    qfc4 = ["; Optional qfc4 complex scan-forwarding surface.\n\n"]
    for name in names:
        qfc4.append(f"""(Rule
  (ParseStmt ({name}))
  {name})

""")
    for name, instrs in [
        ("InitScanForwardingComplex", init_scan_forwarding_complex()),
        ("ScanForwardCarInline", scan_car_inline()),
        ("ScanForwardCdr", scan_cdr()),
        ("CheckScanForwardingComplex", check_scan_forwarding_complex()),
    ]:
        qfc4.append(compile_rule(name, instrs))
        qfc4.append("\n")
    QFC4_EXT_OUT.write_text("".join(qfc4).rstrip() + "\n")

    defs = [
        "(PtrCell HeapNext HeapLimit",
        "(PtrCell Scan Heap",
        "(PtrCell Root OldRoot",
        *data_cell("Heap"),
        *data_cell("HeapLeft"),
        *data_cell("HeapRight"),
        *data_cell("HeapShared"),
        "(Data HeapAfterCopied 00",
        "(Data HeapLimit 00",
        "(RawPairPtrs OldRoot OldLeft OldRight",
        "(RawPairValPtr OldLeft 11 OldShared",
        "(RawPairPtrVal OldRight OldShared 25",
        "(RawPairValPtr OldShared 13 OldShared",
        """(Def
      ScanCdr
      NoFrame
      (ScanForwardCdr)""",
        """(Def
      Start
      NoFrame
      (Seq
        (InitScanForwardingComplex)
        (Seq
          (Local ScanLoop)
          (Seq
            (CallProc ScanCdr)
            (Seq
              (ScanForwardCarInline)
              (Seq
                (AdvanceScanOrLoop ScanLoop)
                (CheckScanForwardingComplex))))))""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 complex scan-forwarding recovery lifted through qfc4.
;
; Compile with qfc4-scan-forwarding-complex-ext.qf1 and the Stage 5 heap/scan
; extensions. The source keeps the scan loop readable while the optional qfc4
; extension owns the long forwarding field handlers and mixed-graph checks.

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


if __name__ == "__main__":
    main()
