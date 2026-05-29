#!/usr/bin/env python3
"""Generate the qfc4-lifted scan-forwarding plus dynamic atom fixture."""

from pathlib import Path

from generate_stage5_copy_bytes_output_qfc4 import data_cell
from generate_stage5_copy_dynamic_atoms_output_gc import init_atom, overwrite_old_cell
from generate_stage5_scan_forwarding_dynamic_atom_gc import (
    scan_car_forward_inline,
    scan_cdr_atom_inline,
)
from generate_stage5_scan_forwarding_qfc4 import compile_rule, do_expr, qfc4_defs_block


ROOT = Path(__file__).resolve().parents[1]
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-scan-forwarding-dynamic-atom-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-scan-forwarding-dynamic-atom-gc-qfc4.qf1"


def bad_status(value):
    return [
        f"(MovEbxImm32 {value})",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def init_scan_forwarding_dynamic_atom():
    return [
        *init_atom("OldAtomCdr", "Chars41", "02"),
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapShared)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel AtomNext)",
        "(MovEbxLabel HeapAtomCdr)",
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


def check_heap_frontier():
    return [
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterPairs)",
        "(CmpEaxEbx)",
        "(IfZero CheckAtomFrontier "
        + do_expr([])
        + " "
        + do_expr(bad_status("03"))
        + ")",
    ]


def check_atom_frontier():
    return [
        "(MovEaxLabel AtomNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterCopied)",
        "(CmpEaxEbx)",
        "(IfZero CheckChildCycle "
        + do_expr([])
        + " "
        + do_expr(bad_status("04"))
        + ")",
    ]


def check_child_cycle():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(LoadEaxCar)",
        "(PopEbx)",
        "(CmpEaxEbx)",
        "(IfZero CheckCopiedAtomCdr "
        + do_expr([])
        + " "
        + do_expr(bad_status("05"))
        + ")",
    ]


def check_copied_atom_cdr():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(AndEaxNotTag)",
        "(CmpEaxLabel HeapAtomCdr)",
        "(IfZero CheckCopiedAtomLength "
        + do_expr([])
        + " "
        + do_expr(bad_status("06"))
        + ")",
    ]


def check_copied_atom_length():
    return [
        "(MovEaxLabel HeapAtomCdr)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 02)",
        "(IfZero ExitOk "
        + do_expr(exit_ok())
        + " "
        + do_expr(bad_status("07"))
        + ")",
    ]


def exit_ok():
    return [
        "(MovEbxImm32 00)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def finish_scan_forwarding_dynamic_atom():
    return [
        *overwrite_old_cell("OldRoot"),
        *overwrite_old_cell("OldShared"),
        *overwrite_old_cell("OldAtomCdr"),
        *check_heap_frontier(),
        *check_atom_frontier(),
        *check_child_cycle(),
        *check_copied_atom_cdr(),
        *check_copied_atom_length(),
    ]


def write_qfc4_extension():
    names = [
        "InitScanForwardingDynamicAtom",
        "ScanForwardDynamicAtomCar",
        "ScanForwardDynamicAtomCdr",
        "FinishScanForwardingDynamicAtom",
    ]

    qfc4 = ["; Optional qfc4 surface for scan-forwarding plus dynamic atoms.\n\n"]
    for name in names:
        qfc4.append(
            f"""(Rule
  (ParseStmt ({name}))
  {name})

"""
        )

    for name, instrs in [
        ("InitScanForwardingDynamicAtom", init_scan_forwarding_dynamic_atom()),
        ("ScanForwardDynamicAtomCar", scan_car_forward_inline()),
        ("ScanForwardDynamicAtomCdr", scan_cdr_atom_inline()),
        ("FinishScanForwardingDynamicAtom", finish_scan_forwarding_dynamic_atom()),
    ]:
        qfc4.append(compile_rule(name, instrs))
        qfc4.append("\n")

    QFC4_EXT_OUT.write_text("".join(qfc4).rstrip() + "\n")


def write_qfc4_source():
    defs = [
        "(PtrCell HeapNext HeapLimit",
        "(PtrCell AtomNext HeapAtomCdr",
        "(PtrCell Scan Heap",
        "(PtrCell Root OldRoot",
        *data_cell("Heap"),
        *data_cell("HeapShared"),
        "(Data HeapAfterPairs 00",
        "(RawPair HeapAtomCdr 00 00",
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
        (InitScanForwardingDynamicAtom)
        (Seq
          (Local ScanLoop)
          (Seq
            (ScanForwardDynamicAtomCar)
            (Seq
              (ScanForwardDynamicAtomCdr)
              (Seq
                (AdvanceScanOrLoop ScanLoop)
                (FinishScanForwardingDynamicAtom))))))""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 scan-forwarding plus dynamic atom-copy fixture lifted through qfc4.
;
; Recovery copies a root pair, then the qfc4-lowered scan loop discovers a
; self-cyclic child through forwarding and copies the child's runtime
; initialized tagged cdr atom into the atom frontier. The generated ELF
; overwrites all old records, verifies the copied cycle, pair and atom
; frontiers, and copied atom length, then exits `0`.

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
