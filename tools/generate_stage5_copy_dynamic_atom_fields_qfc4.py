#!/usr/bin/env python3
"""Generate the qfc4-lifted dynamic atom field-copy fixture."""

from pathlib import Path

from generate_stage5_copy_bytes_output_qfc4 import data_cell
from generate_stage5_copy_dynamic_atom_cdr_gc import scan_cdr_field_dynamic_atoms
from generate_stage5_copy_dynamic_atoms_output_gc import (
    init_atom,
    overwrite_old_cell,
    scan_car_field_dynamic_atoms,
)
from generate_stage5_scan_forwarding_qfc4 import compile_rule, do_expr, qfc4_defs_block


ROOT = Path(__file__).resolve().parents[1]
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-copy-dynamic-atom-fields-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-copy-dynamic-atom-fields-gc-qfc4.qf1"


def init_dynamic_atom_fields_copy():
    return [
        *init_atom("OldAtomCar", "Chars42", "02"),
        *init_atom("OldAtomCdr", "Chars41", "02"),
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapAtomCar)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel AtomNext)",
        "(MovEbxLabel HeapAtomCar)",
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


def check_copied_field(field_load, expected_label, fail_status, ok_label):
    return [
        "(MovEaxLabel Root)",
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


def finish_dynamic_atom_fields_copy():
    return [
        *overwrite_old_cell("OldRoot"),
        *overwrite_old_cell("OldAtomCar"),
        *overwrite_old_cell("OldAtomCdr"),
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAtomCar)",
        "(CmpEaxEbx)",
        "(IfZero CheckAtomNext " + do_expr([]) + " " + do_expr(bad_status("03")) + ")",
        "(MovEaxLabel AtomNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterCopied)",
        "(CmpEaxEbx)",
        "(IfZero CheckCopiedCar " + do_expr([]) + " " + do_expr(bad_status("04")) + ")",
        *check_copied_field("(LoadEaxCar)", "HeapAtomCar", "05", "CheckCopiedCdr"),
        *check_copied_field("(LoadEaxCdr)", "HeapAtomCdr", "06", "EmitCopiedCdr"),
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(Invoke EmitByte Empty)",
        "(MovEbxImm32 00)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def bad_status(value):
    return [
        f"(MovEbxImm32 {value})",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def write_qfc4_extension():
    names = [
        "InitDynamicAtomFieldsCopy",
        "ScanDynamicAtomCar",
        "ScanDynamicAtomCdr",
        "FinishDynamicAtomFieldsCopy",
    ]

    qfc4 = ["; Optional qfc4 surface for dynamic atom field-copy fixture.\n\n"]
    for name in names:
        qfc4.append(
            f"""(Rule
  (ParseStmt ({name}))
  {name})

"""
        )

    for name, instrs in [
        ("InitDynamicAtomFieldsCopy", init_dynamic_atom_fields_copy()),
        ("ScanDynamicAtomCar", scan_car_field_dynamic_atoms()),
        ("ScanDynamicAtomCdr", scan_cdr_field_dynamic_atoms()),
        ("FinishDynamicAtomFieldsCopy", finish_dynamic_atom_fields_copy()),
    ]:
        qfc4.append(compile_rule(name, instrs))
        qfc4.append("\n")

    QFC4_EXT_OUT.write_text("".join(qfc4).rstrip() + "\n")


def write_qfc4_source():
    defs = [
        "(PtrCell HeapNext HeapLimit",
        "(PtrCell AtomNext HeapAtomCar",
        "(PtrCell Scan Heap",
        "(PtrCell Root OldRoot",
        *data_cell("Heap"),
        *data_cell("HeapAtomCar"),
        *data_cell("HeapAtomCdr"),
        "(Data HeapAfterCopied 00",
        "(Data HeapLimit 00",
        "(String2 Chars42 34 32",
        "(String2 Chars41 34 31",
        "(RawPair OldAtomCar 00 00",
        "(RawPair OldAtomCdr 00 00",
        "(Pair OldRoot (Const OldAtomCar) (Const OldAtomCdr)",
        """(Def
      Start
      NoFrame
      (Seq
        (InitDynamicAtomFieldsCopy)
        (Seq
          (Local ScanLoop)
          (Seq
            (ScanDynamicAtomCar)
            (Seq
              (ScanDynamicAtomCdr)
              (Seq
                (AdvanceScanOrLoop ScanLoop)
                (FinishDynamicAtomFieldsCopy))))))""",
        """(Def
      EmitByte
      NoFrame
      (Seq
        (LoadAtomCharsEcx)
        (Seq
          (LoadByteEbxFromEcx)
          (Seq
            (CallProc Nybble)
            (Seq
              (ShlEbx 04)
              (Seq
                (PushEbx)
                (Seq
                  (IncEcx)
                  (Seq
                    (LoadByteEbxFromEcx)
                    (Seq
                      (CallProc Nybble)
                      (Seq
                        (PopEcx)
                        (Seq
                          (OrEbxEcx)
                          (WriteByteFromEbx)))))))))))""",
        """(Def
      Nybble
      NoFrame
      (Seq
        (SubEbx 30)
        (Seq
          (CmpEbx 09)
          (IfBelowEq
            Done
            (Nop)
            (SubEbx 07))))""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 dynamic atom field-copy fixture lifted through qfc4.
;
; Compile with qfc4-copy-dynamic-atom-fields-ext.qf1 and the Stage 5
; heap/scan extensions. The generated ELF copies one pair whose car and cdr are
; runtime-initialized tagged atoms, rewrites both copied fields to copied atom
; records, overwrites the old records, and emits byte `41` from the copied cdr.

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
