#!/usr/bin/env python3
"""Generate the qfc4 Stage 5 root-table forwarding GC fixture."""

from pathlib import Path

from generate_stage5_scan_forwarding_qfc4 import (
    compile_rule,
    do_expr,
    qfc4_defs_block,
)


ROOT = Path(__file__).resolve().parents[1]
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-root-table-forwarding-ext.qf1"
QFASM_EXT_OUT = ROOT / "bootstrap" / "qfasm-root-table-forwarding-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-root-table-forwarding-gc-qfc4.qf1"


def bad_status(value):
    return [
        f"(MovEbxImm32 {value})",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def trace_roots():
    return [
        "(Label TraceRootsLoop)",
        "(MovEaxLabel RootScan)",
        "(LoadEaxCar)",
        "(CmpEaxLabel RootEnd)",
        "(Jnz TraceRootProcess)",
        "(JumpNear TraceRootsDone)",
        "(Label TraceRootProcess)",
        "(Invoke ForwardRootSlot Empty)",
        "(MovEaxLabel RootScan)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(AddEbxImm8 04)",
        "(MovEaxLabel RootScan)",
        "(StoreDwordAtEaxFromEbx)",
        "(JumpNear TraceRootsLoop)",
        "(Label TraceRootsDone)",
    ]


def forward_root_slot():
    return [
        "(PushEax)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(TestAlPair)",
        "(Jz TraceRootPair)",
        "(PopEax)",
        "(PopEax)",
        "(Ret)",
        "(Label TraceRootPair)",
        "(PopEax)",
        "(PushEax)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 0F)",
        "(Jnz TraceRootCopy)",
        "(PopEax)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(PopEax)",
        "(StoreDwordAtEaxFromEbx)",
        "(Ret)",
        "(Label TraceRootCopy)",
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
        "(PopEax)",
        "(StoreDwordAtEaxFromEbx)",
        "(AddEbxImm8 08)",
        "(MovEaxLabel HeapNext)",
        "(StoreDwordAtEaxFromEbx)",
    ]


def check_root_table_forwarding():
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
        "(MovEaxLabel RootSlotA)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel RootSlotB)",
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
        "(MovEaxLabel RootSlotA)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(MovEaxLabel RootSlotA)",
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
        "(MovEaxLabel RootSlotA)",
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
        "(MovEaxLabel RootSlotB)",
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
    QFASM_EXT_OUT.write_text("".join(qfasm))

    names = [
        "TraceRoots",
        "ForwardRootSlot",
        "CheckRootTableForwarding",
    ]

    qfc4 = ["; Optional qfc4 root-table forwarding collector surface.\n\n"]
    qfc4.append("""(Rule
  (ParseStmt (JumpNearProc name))
  (JumpNearProc name))

(Rule
  (CompileStmt (JumpNearProc name))
  (Do (JumpNear name) End))

""")
    for name in names:
        qfc4.append(f"""(Rule
  (ParseStmt ({name}))
  {name})

""")
    for name, instrs in [
        ("TraceRoots", trace_roots()),
        ("ForwardRootSlot", forward_root_slot()),
        ("CheckRootTableForwarding", check_root_table_forwarding()),
    ]:
        qfc4.append(compile_rule(name, instrs))
        qfc4.append("\n")
    QFC4_EXT_OUT.write_text("".join(qfc4).rstrip() + "\n")

    defs = [
        "(PtrCell HeapNext Heap",
        "(PtrCell Scan Heap",
        "(PtrCell RootScan RootSlotA",
        "(PtrCell RootSlotA OldRoot",
        "(PtrCell RootSlotB OldRoot",
        "(Data RootEnd 00",
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
      Start
      NoFrame
      (Seq
        (CallProc TraceRoots)
        (JumpNearProc MainLoop))""",
        """(Def
      TraceRoots
      NoFrame
      (TraceRoots)""",
        """(Def
      ForwardRootSlot
      NoFrame
      (ForwardRootSlot)""",
        """(Def
      ScanCdr
      NoFrame
      (ScanForwardCdr)""",
        """(Def
      MainLoop
      NoFrame
      (Seq
        (Local ScanLoop)
        (Seq
          (CallProc ScanCdr)
          (Seq
            (ScanForwardCarInline)
            (Seq
              (AdvanceScanOrLoop ScanLoop)
              (CheckRootTableForwarding)))))""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 root-table scan-forwarding recovery lifted through qfc4.
;
; Unlike the earlier multi-root fixture, this source traces a contiguous root
; slot table from RootScan to RootEnd. TraceRoots forwards each root slot before
; the shared scan-forwarding loop copies children discovered from the copied
; roots.

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


if __name__ == "__main__":
    main()
