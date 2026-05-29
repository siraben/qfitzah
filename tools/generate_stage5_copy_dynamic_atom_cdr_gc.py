#!/usr/bin/env python3
"""Generate a direct qfasm2 Stage 5 fixture that copies a cdr atom field."""

from pathlib import Path

from generate_stage5_copy_bytes_output_gc import emit_byte_proc, scan_car_field
from generate_stage5_copy_dynamic_atoms_output_gc import init_atom, overwrite_old_cell
from generate_stage5_copy_tree_gc import cell, ins_block


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "bootstrap" / "stage5-copy-dynamic-atom-cdr-gc.qf1"


def scan_cdr_field_dynamic_atoms():
    return [
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(PushEax)",
        "(TestAlPair)",
        "(Jnz CdrNotPair)",
        "(Label CopyCdrPair)",
        "(PopEax)",
        "(LoadEbxCarFromEax)",
        "(LoadEcxCdrFromEax)",
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxFromEbx)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEbxEax)",
        "(MovEcxEbx)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(AddEbxImm8 08)",
        "(MovEaxLabel HeapNext)",
        "(StoreDwordAtEaxFromEbx)",
        "(Jump FinishCdr)",
        "(Label CdrNotPair)",
        "(PopEax)",
        "(CmpEaxImm8 01)",
        "(Jz FinishCdr)",
        "(AndEaxNotTag)",
        "(LoadEbxCarFromEax)",
        "(LoadEcxCdrFromEax)",
        "(MovEaxLabel AtomNext)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxFromEbx)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEbxEax)",
        "(AddEbxImm8 01)",
        "(MovEcxEbx)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel AtomNext)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(AddEbxImm8 08)",
        "(MovEaxLabel AtomNext)",
        "(StoreDwordAtEaxFromEbx)",
        "(Label FinishCdr)",
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


def main():
    instrs = [
        "(Label HeapNext)",
        "(DwordLabel HeapLimit)",
        "(Label AtomNext)",
        "(DwordLabel HeapAtom41)",
        "(Label Scan)",
        "(DwordLabel Heap)",
        "(Label Root)",
        "(DwordLabel OldRoot)",
        *cell("Heap"),
        "(Label HeapAfterPairs)",
        *cell("HeapAtom41"),
        "(Label HeapAfterCopied)",
        "(Label HeapLimit)",
        "(Db 00)",
        "(Align4)",
        "(Label Chars41)",
        "(Db 34)",
        "(Db 31)",
        "(Align4)",
        *cell("OldAtom41"),
        "(Label OldRoot)",
        "(DwordNil)",
        "(DwordConst OldAtom41)",
        "(Align4)",
        "(Label Start)",
        *init_atom("OldAtom41", "Chars41", "02"),
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapAfterPairs)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel AtomNext)",
        "(MovEbxLabel HeapAtom41)",
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
        *scan_car_field(),
        *scan_cdr_field_dynamic_atoms(),
        *advance_scan_or_loop(),
        "(Label ScanDone)",
        *overwrite_old_cell("OldRoot"),
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
        "(Jz CheckCopiedCdr)",
        "(MovEbxImm32 04)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label CheckCopiedCdr)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(AndEaxNotTag)",
        "(CmpEaxLabel HeapAtom41)",
        "(Jz EmitCopiedCdr)",
        "(MovEbxImm32 05)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label EmitCopiedCdr)",
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

    text = """; Stage 5 GC plus dynamic cdr-atom copy fixture.
;
; Recovery copies a root pair whose cdr is a runtime-initialized tagged atom.
; The pair scan frontier remains separate from the atom frontier. The cdr field
; is rewritten to a tagged copied atom, then the old atom is overwritten before
; the generated ELF emits byte `41` (`A`) from the copied cdr atom.

(Assemble
  (Program
    Start
"""
    text += ins_block(instrs)
    text += "\n))\n"
    OUT.write_text(text)


if __name__ == "__main__":
    main()
