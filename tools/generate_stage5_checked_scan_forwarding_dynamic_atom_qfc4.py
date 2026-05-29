#!/usr/bin/env python3
"""Generate the qfc4-lifted checked scan-forwarding dynamic atom fixture."""

from pathlib import Path

from generate_stage5_copy_bytes_output_qfc4 import data_cell
from generate_stage5_copy_dynamic_atoms_output_gc import init_atom, overwrite_old_cell
from generate_stage5_scan_forwarding_dynamic_atom_gc import (
    scan_car_forward_inline,
    scan_cdr_atom_inline,
)
from generate_stage5_scan_forwarding_dynamic_atom_qfc4 import (
    bad_status,
    check_atom_frontier,
    check_child_cycle,
    exit_ok,
)
from generate_stage5_scan_forwarding_qfc4 import compile_rule, do_expr, qfc4_defs_block


ROOT = Path(__file__).resolve().parents[1]
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-checked-scan-forwarding-dynamic-atom-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-checked-scan-forwarding-dynamic-atom-gc-qfc4.qf1"


def initial_checked_overflow():
    return [
        *init_atom("OldAtomCdr", "Chars41", "02"),
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(MovEbxEax)",
        "(AddEbxImm8 08)",
        "(CmpEbxLabel HeapLimit)",
        "(IfBelowEq UnexpectedInitialCommit "
        + do_expr(bad_status("08"))
        + " (Do (Jump Recover) End))",
    ]


def recover_live_graph():
    return [
        "(Label Recover)",
        "(PopEax)",
        "(MovEaxLabel AtomNext)",
        "(MovEbxLabel HeapAfterRetry)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapShared)",
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


def commit_retry_body():
    return [
        "(MovEaxLabel HeapNext)",
        "(StoreDwordAtEaxFromEbx)",
        "(PopEax)",
        "(MovEbxImm32 2A)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 01)",
        "(StoreDwordAtEaxPlus4FromEcx)",
    ]


def retry_checked_allocation():
    return [
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(MovEbxEax)",
        "(AddEbxImm8 08)",
        "(CmpEbxLabel HeapLimit)",
        "(IfBelowEq CommitRetry "
        + do_expr(commit_retry_body())
        + " "
        + do_expr(bad_status("09"))
        + ")",
    ]


def check_heap_frontier_after_retry():
    return [
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterRetry)",
        "(CmpEaxEbx)",
        "(IfZero CheckAtomFrontier "
        + do_expr([])
        + " "
        + do_expr(bad_status("03"))
        + ")",
    ]


def check_retry_nil():
    return [
        "(MovEaxLabel HeapRetry)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 01)",
        "(IfZero ExitOk " + do_expr(exit_ok()) + " " + do_expr(bad_status("0B")) + ")",
    ]


def check_retry_pair():
    return [
        "(MovEaxLabel HeapRetry)",
        "(LoadEaxCar)",
        "(CmpEaxImm8 2A)",
        "(IfZero CheckRetryNil "
        + do_expr(check_retry_nil())
        + " "
        + do_expr(bad_status("0A"))
        + ")",
    ]


def check_copied_atom_cdr():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(AndEaxNotTag)",
        "(CmpEaxLabel HeapAfterRetry)",
        "(IfZero CheckCopiedAtomLength "
        + do_expr([])
        + " "
        + do_expr(bad_status("06"))
        + ")",
    ]


def check_copied_atom_length_then_retry():
    return [
        "(MovEaxLabel HeapAfterRetry)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 02)",
        "(IfZero CheckRetryPair "
        + do_expr(check_retry_pair())
        + " "
        + do_expr(bad_status("07"))
        + ")",
    ]


def finish_checked_scan_forwarding_dynamic_atom():
    return [
        *overwrite_old_cell("OldRoot"),
        *overwrite_old_cell("OldShared"),
        *overwrite_old_cell("OldAtomCdr"),
        *check_heap_frontier_after_retry(),
        *check_atom_frontier(),
        *check_child_cycle(),
        *check_copied_atom_cdr(),
        *check_copied_atom_length_then_retry(),
    ]


def write_qfc4_extension():
    names = [
        "InitialCheckedOverflow",
        "RecoverCheckedScanForwardingDynamicAtom",
        "CheckedScanForwardDynamicAtomCar",
        "CheckedScanForwardDynamicAtomCdr",
        "RetryCheckedAllocation",
        "FinishCheckedScanForwardingDynamicAtom",
    ]

    qfc4 = ["; Optional qfc4 surface for checked scan-forwarding plus dynamic atoms.\n\n"]
    for name in names:
        qfc4.append(
            f"""(Rule
  (ParseStmt ({name}))
  {name})

"""
        )

    for name, instrs in [
        ("InitialCheckedOverflow", initial_checked_overflow()),
        ("RecoverCheckedScanForwardingDynamicAtom", recover_live_graph()),
        ("CheckedScanForwardDynamicAtomCar", scan_car_forward_inline()),
        ("CheckedScanForwardDynamicAtomCdr", scan_cdr_atom_inline()),
        ("RetryCheckedAllocation", retry_checked_allocation()),
        (
            "FinishCheckedScanForwardingDynamicAtom",
            finish_checked_scan_forwarding_dynamic_atom(),
        ),
    ]:
        qfc4.append(compile_rule(name, instrs))
        qfc4.append("\n")

    QFC4_EXT_OUT.write_text("".join(qfc4).rstrip() + "\n")


def write_qfc4_source():
    defs = [
        "(PtrCell HeapNext HeapLimit",
        "(PtrCell AtomNext HeapAfterRetry",
        "(PtrCell Scan Heap",
        "(PtrCell Root OldRoot",
        *data_cell("Heap"),
        *data_cell("HeapShared"),
        *data_cell("HeapRetry"),
        "(RawPair HeapAfterRetry 00 00",
        "(Data HeapAfterCopied 00",
        "(Data HeapLimit 00",
        "(String2 Chars41 34 31",
        "(RawPair OldAtomCdr 00 00",
        "(Pair OldRoot (Ptr OldShared) Nil",
        "(Pair OldShared (Ptr OldShared) (Const OldAtomCdr)",
        """(Def
      Start
      NoFrame
      (Seq
        (InitialCheckedOverflow)
        (Seq
          (RecoverCheckedScanForwardingDynamicAtom)
          (Seq
            (Local ScanLoop)
            (Seq
              (CheckedScanForwardDynamicAtomCar)
              (Seq
                (CheckedScanForwardDynamicAtomCdr)
                (Seq
                  (AdvanceScanOrLoop ScanLoop)
                  (Seq
                    (RetryCheckedAllocation)
                    (FinishCheckedScanForwardingDynamicAtom))))))))""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 checked allocation plus scan-forwarding dynamic atom GC lifted through qfc4.
;
; The staged source starts HeapNext at HeapLimit so the first checked pair
; allocation must overflow. Recovery copies the live cyclic graph, copies the
; runtime-initialized cdr atom into the atom frontier, retries allocation after
; the copied graph, overwrites old records, verifies the copied data plus retry
; pair, and exits `0`.

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


def main():
    write_qfc4_extension()
    write_qfc4_source()


if __name__ == "__main__":
    main()
