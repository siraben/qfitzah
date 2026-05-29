#!/usr/bin/env python3
"""Generate the qfc4-lifted nested dynamic atom-copy fixture."""

from pathlib import Path

from generate_stage5_copy_bytes_output_qfc4 import data_cell
from generate_stage5_copy_dynamic_atom_cdr_gc import scan_cdr_field_dynamic_atoms
from generate_stage5_copy_dynamic_atoms_output_gc import (
    init_atom,
    overwrite_old_cell,
)
from generate_stage5_scan_forwarding_qfc4 import compile_rule, do_expr, qfc4_defs_block


ROOT = Path(__file__).resolve().parents[1]
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-copy-dynamic-atom-nested-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-copy-dynamic-atom-nested-gc-qfc4.qf1"


def bad_status(value):
    return [
        f"(MovEbxImm32 {value})",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def init_dynamic_atom_nested_copy():
    return [
        *init_atom("OldAtomCdr", "Chars41", "02"),
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapChild)",
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


def dynamic_atom_nested_loop():
    return [
        "(Label ScanLoop)",
    ]


def advance_dynamic_atom_nested_loop():
    return [
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(AddEbxImm8 08)",
        "(MovEaxLabel Scan)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(CmpEaxEbx)",
        "(JnzNear ScanLoop)",
    ]


def check_copied_child():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(CmpEaxLabel HeapChild)",
        "(IfZero CheckAtomNext " + do_expr([]) + " " + do_expr(bad_status("02")) + ")",
    ]


def check_copied_child_field(field_load, expected_label, fail_status, ok_label):
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        field_load,
        "(AndEaxNotTag)",
        f"(CmpEaxLabel {expected_label})",
        "(IfZero "
        + ok_label
        + " "
        + do_expr([])
        + " "
        + do_expr(bad_status(fail_status))
        + ")",
    ]


def finish_dynamic_atom_nested_copy():
    return [
        *overwrite_old_cell("OldRoot"),
        *overwrite_old_cell("OldChild"),
        *overwrite_old_cell("OldAtomCdr"),
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterPairs)",
        "(CmpEaxEbx)",
        "(IfZero CheckCopiedChild " + do_expr([]) + " " + do_expr(bad_status("03")) + ")",
        *check_copied_child(),
        "(MovEaxLabel AtomNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterCopied)",
        "(CmpEaxEbx)",
        "(IfZero CheckCopiedCdr " + do_expr([]) + " " + do_expr(bad_status("04")) + ")",
        *check_copied_child_field("(LoadEaxCdr)", "HeapAtomCdr", "06", "ExitOk"),
        "(MovEbxImm32 00)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def write_qfc4_extension():
    names = [
        "InitDynamicAtomNestedCopy",
        "DynamicAtomNestedLoop",
        "ScanDynamicAtomCdr",
        "AdvanceDynamicAtomNestedLoop",
        "FinishDynamicAtomNestedCopy",
    ]

    qfc4 = ["; Optional qfc4 surface for nested dynamic atom-copy fixture.\n\n"]
    for name in names:
        qfc4.append(
            f"""(Rule
  (ParseStmt ({name}))
  {name})

"""
        )

    for name, instrs in [
        ("InitDynamicAtomNestedCopy", init_dynamic_atom_nested_copy()),
        ("DynamicAtomNestedLoop", dynamic_atom_nested_loop()),
        ("ScanDynamicAtomCdr", scan_cdr_field_dynamic_atoms()),
        ("AdvanceDynamicAtomNestedLoop", advance_dynamic_atom_nested_loop()),
        ("FinishDynamicAtomNestedCopy", finish_dynamic_atom_nested_copy()),
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
        *data_cell("HeapChild"),
        "(Data HeapAfterPairs 00",
        "(RawPair HeapAtomCdr 00 00",
        "(Data HeapAfterCopied 00",
        "(Data HeapLimit 00",
        "(String2 Chars41 34 31",
        "(RawPair OldAtomCdr 00 00",
        "(Pair OldRoot (Ptr OldChild) Nil",
        "(Pair OldChild Nil (Const OldAtomCdr)",
        """(Def
      Start
      NoFrame
      (Seq
        (InitDynamicAtomNestedCopy)
        (Seq
          (DynamicAtomNestedLoop)
          (Seq
            (ScanCarField)
            (Seq
              (ScanDynamicAtomCdr)
              (Seq
                (AdvanceDynamicAtomNestedLoop)
                (FinishDynamicAtomNestedCopy))))))""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 nested dynamic atom-copy fixture lifted through qfc4.
;
; Recovery first copies a root pair, then the scan loop discovers and copies
; its child pair. Only when that copied child is scanned is its runtime
; initialized tagged cdr atom copied into the atom frontier. The generated ELF
; overwrites all old records, verifies the child cdr was rewritten to the copied
; atom record, and exits `0`.

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
