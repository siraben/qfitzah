#!/usr/bin/env python3
"""Generate the qfc4 checked root-table forwarding GC fixture."""

from pathlib import Path

from generate_stage5_root_table_forwarding_qfc4 import bad_status
from generate_stage5_scan_forwarding_qfc4 import compile_rule, do_expr, qfc4_defs_block
from stage5_checked_root_table_common_qfc4 import (
    write_checked_root_table_common_ext,
)


ROOT = Path(__file__).resolve().parents[1]
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-checked-root-table-forwarding-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-checked-root-table-forwarding-gc-qfc4.qf1"


def recover_root_table():
    return [
        "(Label Recover)",
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel RootScan)",
        "(MovEbxLabel RootSlotA)",
        "(StoreDwordAtEaxFromEbx)",
    ]


def recover_root_table_and_trace():
    return [
        *recover_root_table(),
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
        "(JumpNear AfterTrace)",
    ]


def overwrite_old_graph():
    return [
        "(MovEaxLabel OldRoot)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
    ]


def check_root_table_forwarding():
    return [
        "(MovEaxLabel RootSlotA)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel RootSlotB)",
        "(LoadEaxCar)",
        "(CmpEaxEbx)",
        "(JnzNear FailRootsShared)",
        *check_heap_next_after_retry(),
    ]


def check_heap_next_after_retry():
    return [
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterRetry)",
        "(CmpEaxEbx)",
        "(JnzNear FailHeapNext)",
        *check_retry_pair(),
    ]


def check_retry_pair():
    return [
        "(MovEaxLabel HeapAfterCopied)",
        "(LoadEaxCar)",
        "(CmpEaxImm8 2A)",
        "(JnzNear FailRetryCar)",
        *exit_copied_child(),
        "(Label FailRootsShared)",
        *bad_status("01"),
        "(Label FailHeapNext)",
        *bad_status("05"),
        "(Label FailRetryCar)",
        *bad_status("0A"),
    ]


def exit_copied_child():
    return [
        "(MovEaxLabel RootSlotB)",
        "(LoadEaxCar)",
        "(LoadEbxCarFromEax)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def finish_checked_root_table():
    return [
        *overwrite_old_graph(),
        *check_root_table_forwarding(),
    ]


def write_qfc4_extension():
    names = [
        "RecoverRootTableAndTrace",
        "FinishCheckedRootTableForwarding",
    ]

    qfc4 = ["; Optional qfc4 surface for checked root-table forwarding GC.\n\n"]
    for name in names:
        qfc4.append(
            f"""(Rule
  (ParseStmt ({name}))
  {name})

"""
        )

    for name, instrs in [
        ("RecoverRootTableAndTrace", recover_root_table_and_trace()),
        ("FinishCheckedRootTableForwarding", finish_checked_root_table()),
    ]:
        qfc4.append(compile_rule(name, instrs))
        qfc4.append("\n")

    QFC4_EXT_OUT.write_text("".join(qfc4).rstrip() + "\n")


def write_qfc4_source():
    defs = [
        "(PtrCell HeapNext HeapLimit",
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
        "(RawPair OldRoot 13 17",
        """(Def
      Start
      NoFrame
      (Seq
        (InitialCheckedRootTableOverflow)
        (JumpNearProc Recover))""",
        """(Def
      Recover
      NoFrame
      (RecoverRootTableAndTrace)""",
        """(Def
      ForwardRootSlot
      NoFrame
      (ForwardRootSlot)""",
        """(Def
      AfterTrace
      NoFrame
      (Seq
        (RetryCheckedRootTableAllocation)
        (FinishCheckedRootTableForwarding))""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 checked allocation plus root-table forwarding lifted through qfc4.
;
; HeapNext starts at HeapLimit so the first checked allocation must overflow.
; Recovery resets the pair frontier, traces the RootScan..RootEnd table, retries
; allocation after the copied root, overwrites the old root, and verifies both
; copied live data and the retry pair before exiting through the copied root car
; (`19`).

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
