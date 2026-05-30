#!/usr/bin/env python3
"""Generate the qfc4 checked root-table scan-forwarding GC fixture."""

from pathlib import Path

from generate_stage5_root_table_forwarding_qfc4 import bad_status
from generate_stage5_scan_forwarding_qfc4 import compile_rule, do_expr, qfc4_defs_block
from stage5_checked_root_table_common_qfc4 import (
    write_checked_root_table_common_ext,
)


ROOT = Path(__file__).resolve().parents[1]
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-checked-root-table-scan-forwarding-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-checked-root-table-scan-forwarding-gc-qfc4.qf1"


def overwrite_old_graph():
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
    ]


def trace_roots_to_main_loop():
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
        "(JumpNear MainLoop)",
    ]


def finish_checked_scan_forwarding():
    return [
        *overwrite_old_graph(),
        "(MovEaxLabel RootSlotA)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel RootSlotB)",
        "(LoadEaxCar)",
        "(CmpEaxEbx)",
        "(JnzNear FailRootsShared)",
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterRetry)",
        "(CmpEaxEbx)",
        "(JnzNear FailHeapNext)",
        "(MovEaxLabel HeapAfterCopied)",
        "(LoadEaxCar)",
        "(CmpEaxImm8 2A)",
        "(JnzNear FailRetryCar)",
        "(MovEaxLabel RootSlotB)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEbxCarFromEax)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label FailRootsShared)",
        *bad_status("01"),
        "(Label FailHeapNext)",
        *bad_status("05"),
        "(Label FailRetryCar)",
        *bad_status("0A"),
    ]


def write_qfc4_extension():
    names = [
        "TraceRootTableForScan",
        "FinishCheckedRootTableScanForwarding",
    ]

    qfc4 = ["; Optional qfc4 surface for checked root-table scan-forwarding GC.\n\n"]
    for name in names:
        qfc4.append(
            f"""(Rule
  (ParseStmt ({name}))
  {name})

"""
        )

    for name, instrs in [
        ("TraceRootTableForScan", trace_roots_to_main_loop()),
        ("FinishCheckedRootTableScanForwarding", finish_checked_scan_forwarding()),
    ]:
        qfc4.append(compile_rule(name, instrs))
        qfc4.append("\n")

    QFC4_EXT_OUT.write_text("".join(qfc4).rstrip() + "\n")


def write_qfc4_source():
    defs = [
        "(PtrCell HeapNext HeapLimit",
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
        "(Data HeapRetry1 00",
        "(Data HeapRetry2 00",
        "(Data HeapRetry3 00",
        "(Data HeapRetry4 00",
        "(Data HeapRetry5 00",
        "(Data HeapRetry6 00",
        "(Data HeapRetry7 00",
        "(Data HeapAfterRetry 00",
        "(Data HeapLimit 00",
        "(RawPairPtrs OldRoot OldChild OldChild",
        "(RawPairValPtr OldChild 13 OldChild",
        """(Def
      Start
      NoFrame
      (Seq
        (InitialCheckedRootTableOverflow)
        (JumpNearProc Recover))""",
        """(Def
      Recover
      NoFrame
      (Seq
        (ResetCheckedRootTableScan)
        (TraceRootTableForScan))""",
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
              (Seq
                (RetryCheckedRootTableAllocation)
                (FinishCheckedRootTableScanForwarding))))))""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 checked allocation plus root-table scan-forwarding lifted through qfc4.
;
; HeapNext starts at HeapLimit so the first checked allocation must overflow.
; Recovery traces the RootScan..RootEnd table, the scan-forwarding loop copies
; the shared cyclic child, allocation retries after the copied graph, and the
; generated ELF verifies root convergence, the retry cell, and copied child data
; before exiting `19`.

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


def main():
    write_checked_root_table_common_ext()
    write_qfc4_extension()
    write_qfc4_source()


if __name__ == "__main__":
    main()
