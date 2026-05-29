#!/usr/bin/env python3
"""Generate a direct qfasm2 Stage 5 fixture that copies runtime atom cells."""

from pathlib import Path

from generate_stage5_copy_bytes_isbytes_output_gc import is_bytes_proc, nybble_proc
from generate_stage5_copy_bytes_output_gc import (
    emit_byte_proc,
    scan_cdr_field,
)
from generate_stage5_copy_tree_gc import cell, ins_block


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "bootstrap" / "stage5-copy-dynamic-atoms-output-gc.qf1"


def overwrite_old_cell(label):
    return [
        f"(MovEaxLabel {label})",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
    ]


def init_atom(label, chars, length):
    return [
        f"(MovEaxLabel {label})",
        f"(MovEbxLabel {chars})",
        "(StoreDwordAtEaxFromEbx)",
        f"(MovEcxImm32 {length})",
        "(StoreDwordAtEaxPlus4FromEcx)",
    ]


def scan_car_field_dynamic_atoms():
    return [
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(TestAlPair)",
        "(Jnz CarNotPair)",
        "(Label CopyCarPair)",
        "(PopEax)",
        "(LoadEbxCarFromEax)",
        "(LoadEcxCdrFromEax)",
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxFromEbx)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEbxEax)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxFromEbx)",
        "(AddEbxImm8 08)",
        "(MovEaxLabel HeapNext)",
        "(StoreDwordAtEaxFromEbx)",
        "(Jump FinishCar)",
        "(Label CarNotPair)",
        "(PopEax)",
        "(CmpEaxImm8 01)",
        "(Jz FinishCar)",
        "(AndEaxNotTag)",
        "(LoadEbxCarFromEax)",
        "(LoadEcxCdrFromEax)",
        "(MovEaxLabel AtomNext)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxFromEbx)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEbxEax)",
        "(AddEbxImm8 01)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel AtomNext)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(AddEbxImm8 08)",
        "(MovEaxLabel AtomNext)",
        "(StoreDwordAtEaxFromEbx)",
        "(Label FinishCar)",
    ]


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


def emit_copied_byte():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(LoadEaxCar)",
        "(Call EmitByte)",
        "(MovEbxImm32 00)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def main():
    instrs = [
        "(Label HeapNext)",
        "(DwordLabel HeapLimit)",
        "(Label AtomNext)",
        "(DwordLabel HeapAtomBytes)",
        "(Label Scan)",
        "(DwordLabel Heap)",
        "(Label Root)",
        "(DwordLabel OldBytesExpr)",
        *cell("Heap"),
        *cell("HeapTail"),
        "(Label HeapAfterPairs)",
        *cell("HeapAtomBytes"),
        *cell("HeapAtom41"),
        "(Label HeapAfterCopied)",
        "(Label HeapLimit)",
        "(Db 00)",
        "(Align4)",
        "(Label BytesChars)",
        "(Db 42)",
        "(Db 79)",
        "(Db 74)",
        "(Db 65)",
        "(Db 73)",
        "(Align4)",
        "(Label Chars41)",
        "(Db 34)",
        "(Db 31)",
        "(Align4)",
        *cell("OldAtomBytes"),
        *cell("OldAtom41"),
        "(Label OldBytesExpr)",
        "(DwordConst OldAtomBytes)",
        "(DwordLabel OldBytesTail)",
        "(Label OldBytesTail)",
        "(DwordConst OldAtom41)",
        "(DwordNil)",
        "(Align4)",
        "(Label Start)",
        *init_atom("OldAtomBytes", "BytesChars", "05"),
        *init_atom("OldAtom41", "Chars41", "02"),
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(AddEbxImm8 08)",
        "(CmpEbxLabel HeapLimit)",
        "(Jbe UnexpectedCommit)",
        "(Jump Recover)",
        "(Label UnexpectedCommit)",
        "(MovEbxImm32 07)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label Recover)",
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapTail)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel AtomNext)",
        "(MovEbxLabel HeapAtomBytes)",
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
        *scan_cdr_field(),
        *advance_scan_or_loop(),
        "(Label ScanDone)",
        *overwrite_old_cell("OldBytesExpr"),
        *overwrite_old_cell("OldBytesTail"),
        *overwrite_old_cell("OldAtomBytes"),
        *overwrite_old_cell("OldAtom41"),
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
        "(Jz CheckCopiedBytes)",
        "(MovEbxImm32 04)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label CheckCopiedBytes)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(Call IsBytes)",
        "(Jz EmitCopiedByte)",
        "(MovEbxImm32 01)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label EmitCopiedByte)",
        *emit_copied_byte(),
        *is_bytes_proc(),
        *emit_byte_proc(),
        *nybble_proc(),
    ]

    text = """; Stage 5 GC plus dynamic atom-copy byte-output fixture.
;
; Start initializes the two atom records for `(Bytes 41)` at runtime in
; writable cells, then forces recovery. The scan frontier copies only pairs;
; tagged atom fields in pair cars are copied into a separate atom frontier and
; rewritten to tagged copied atoms. After recovery, all old pairs and old atom
; records are overwritten. The generated ELF then verifies the copied `Bytes`
; atom by content and emits byte `41` (`A`) from the copied byte atom.

(Assemble
  (Program
    Start
"""
    text += ins_block(instrs)
    text += "\n))\n"
    OUT.write_text(text)


if __name__ == "__main__":
    main()
