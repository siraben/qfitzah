#!/usr/bin/env python3
"""Generate the qfc4-lifted Stage 5 multi-root forwarding GC fixture."""

from pathlib import Path

from generate_stage5_scan_forwarding_qfc4 import (
    compile_rule,
    do_expr,
    qfc4_defs_block,
)


ROOT = Path(__file__).resolve().parents[1]
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-multi-root-forwarding-ext.qf1"
QFASM_EXT_OUT = ROOT / "bootstrap" / "qfasm-multi-root-forwarding-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-multi-root-forwarding-gc-qfc4.qf1"


def bad_status(value):
    return [
        f"(MovEbxImm32 {value})",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def use_forwarded_root_b():
    return [
        "(PopEax)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel RootB)",
        "(StoreDwordAtEaxFromEbx)",
    ]


def init_multi_root_forwarding():
    return [
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapChild)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel Scan)",
        "(MovEbxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel RootA)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(LoadEbxCarFromEax)",
        "(LoadEcxCdrFromEax)",
        "(MovEaxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(PopEax)",
        "(MovEbxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 0F)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel RootA)",
        "(MovEbxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel RootB)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 0F)",
        "(IfZero UseForwardedRootB "
        + do_expr(use_forwarded_root_b())
        + " "
        + do_expr(bad_status("04"))
        + ")",
    ]


def check_multi_root_forwarding():
    return [
        "(MovEaxLabel OldRoot)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel OldChild)",
        "(MovEbxImm32 5E)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 6F)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel RootA)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel RootB)",
        "(LoadEaxCar)",
        "(CmpEaxEbx)",
        "(IfZero RootsShared "
        + do_expr(check_root_fields())
        + " "
        + do_expr(bad_status("01"))
        + ")",
    ]


def check_root_fields():
    return [
        "(MovEaxLabel RootA)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(MovEaxLabel RootA)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(PopEbx)",
        "(CmpEaxEbx)",
        "(IfZero FieldsShared "
        + do_expr(check_child_cycle())
        + " "
        + do_expr(bad_status("02"))
        + ")",
    ]


def check_child_cycle():
    return [
        "(MovEaxLabel RootA)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(LoadEaxCdr)",
        "(PopEbx)",
        "(CmpEaxEbx)",
        "(IfZero ChildCycleOk "
        + do_expr(check_heap_next())
        + " "
        + do_expr(bad_status("03"))
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
        + do_expr(bad_status("05"))
        + ")",
    ]


def exit_copied_child():
    return [
        "(MovEaxLabel RootB)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEbxCarFromEax)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def main():
    qfasm = []
    for n in range(219, 241):
        qfasm.append(f"(Inc N{n}) N{n + 1}\n")
    qfasm.append("\n")
    for n in range(221, 242):
        qfasm.append(f"(Dec N{n}) N{n - 1}\n")
    qfasm.append("\n")
    qfasm.append("(Byte (Neg N229)) 1B\n")
    QFASM_EXT_OUT.write_text("".join(qfasm))

    names = [
        "InitMultiRootForwarding",
        "CheckMultiRootForwarding",
    ]

    qfc4 = ["; Optional qfc4 multi-root forwarding surface.\n\n"]
    for name in names:
        qfc4.append(f"""(Rule
  (ParseStmt ({name}))
  {name})

""")
    for name, instrs in [
        ("InitMultiRootForwarding", init_multi_root_forwarding()),
        ("CheckMultiRootForwarding", check_multi_root_forwarding()),
    ]:
        qfc4.append(compile_rule(name, instrs))
        qfc4.append("\n")
    QFC4_EXT_OUT.write_text("".join(qfc4).rstrip() + "\n")

    defs = [
        "(PtrCell HeapNext HeapLimit",
        "(PtrCell Scan Heap",
        "(PtrCell RootA OldRoot",
        "(PtrCell RootB OldRoot",
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
        "(RawPairPtrs OldRoot OldChild OldChild",
        "(RawPairValPtr OldChild 13 OldChild",
        """(Def
      ScanCdr
      NoFrame
      (ScanForwardCdr)""",
        """(Def
      Start
      NoFrame
      (Seq
        (InitMultiRootForwarding)
        (Seq
          (Local ScanLoop)
          (Seq
            (CallProc ScanCdr)
            (Seq
              (ScanForwardCarInline)
              (Seq
                (AdvanceScanOrLoop ScanLoop)
                (CheckMultiRootForwarding))))))""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 multi-root scan-forwarding recovery lifted through qfc4.
;
; Compile with qfc4-scan-forwarding-ext.qf1,
; qfc4-multi-root-forwarding-ext.qf1, and the Stage 5 heap/scan extensions.
; The source reuses the common scan-forwarding field handlers and keeps only
; root-set initialization/checking in the multi-root overlay.

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


if __name__ == "__main__":
    main()
