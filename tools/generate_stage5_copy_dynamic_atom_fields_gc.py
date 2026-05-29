#!/usr/bin/env python3
"""Generate a direct qfasm2 Stage 5 fixture that copies car and cdr atoms."""

from pathlib import Path

from generate_stage5_copy_bytes_output_gc import emit_byte_proc
from generate_stage5_copy_dynamic_atom_cdr_gc import scan_cdr_field_dynamic_atoms
from generate_stage5_copy_dynamic_atoms_output_gc import (
    init_atom,
    overwrite_old_cell,
    scan_car_field_dynamic_atoms,
)
from generate_stage5_copy_tree_gc import cell, ins_block


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "bootstrap" / "stage5-copy-dynamic-atom-fields-gc.qf1"


def advance_scan_or_loop():
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


def check_copied_field(field_load, expected_label, fail_status, ok_label):
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        field_load,
        "(AndEaxNotTag)",
        f"(CmpEaxLabel {expected_label})",
        f"(Jz {ok_label})",
        f"(MovEbxImm32 {fail_status:02X})",
        "(MovEaxImm32 01)",
        "(Int 80)",
        f"(Label {ok_label})",
    ]


def main():
    instrs = [
        "(Label HeapNext)",
        "(DwordLabel HeapLimit)",
        "(Label AtomNext)",
        "(DwordLabel HeapAtomCar)",
        "(Label Scan)",
        "(DwordLabel Heap)",
        "(Label Root)",
        "(DwordLabel OldRoot)",
        *cell("Heap"),
        "(Label HeapAfterPairs)",
        *cell("HeapAtomCar"),
        *cell("HeapAtomCdr"),
        "(Label HeapAfterCopied)",
        "(Label HeapLimit)",
        "(Db 00)",
        "(Align4)",
        "(Label Chars42)",
        "(Db 34)",
        "(Db 32)",
        "(Align4)",
        "(Label Chars41)",
        "(Db 34)",
        "(Db 31)",
        "(Align4)",
        *cell("OldAtomCar"),
        *cell("OldAtomCdr"),
        "(Label OldRoot)",
        "(DwordConst OldAtomCar)",
        "(DwordConst OldAtomCdr)",
        "(Align4)",
        "(Label Start)",
        *init_atom("OldAtomCar", "Chars42", "02"),
        *init_atom("OldAtomCdr", "Chars41", "02"),
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapAfterPairs)",
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
        "(Label ScanLoop)",
        *scan_car_field_dynamic_atoms(),
        *scan_cdr_field_dynamic_atoms(),
        *advance_scan_or_loop(),
        "(Label ScanDone)",
        *overwrite_old_cell("OldRoot"),
        *overwrite_old_cell("OldAtomCar"),
        *overwrite_old_cell("OldAtomCdr"),
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterPairs)",
        "(CmpEaxEbx)",
        "(Jz CheckAtomNext)",
        "(MovEbxImm32 03)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label CheckAtomNext)",
        "(MovEaxLabel AtomNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterCopied)",
        "(CmpEaxEbx)",
        "(Jz CheckCopiedCar)",
        "(MovEbxImm32 04)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label CheckCopiedCar)",
        *check_copied_field("(LoadEaxCar)", "HeapAtomCar", 5, "CheckCopiedCdr"),
        *check_copied_field("(LoadEaxCdr)", "HeapAtomCdr", 6, "EmitCopiedCdr"),
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(Call EmitByte)",
        "(MovEbxImm32 00)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        *emit_byte_proc(),
        "(Label Nybble)",
        "(SubEbxImm8 30)",
        "(CmpEbxImm8 09)",
        "(Jbe NybbleDone)",
        "(SubEbxImm8 07)",
        "(Label NybbleDone)",
        "(Ret)",
    ]

    text = """; Stage 5 GC dynamic atom field-copy fixture.
;
; Recovery copies one root pair whose car and cdr are both runtime-initialized
; tagged atoms. The scan loop copies both atom records into a separate atom
; frontier, rewrites both copied fields, overwrites all old records, verifies
; both rewritten fields, then emits byte `41` (`A`) from the copied cdr atom.

(Assemble
  (Program
    Start
"""
    text += ins_block(instrs)
    text += "\n))\n"
    OUT.write_text(text)


if __name__ == "__main__":
    main()
