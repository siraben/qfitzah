#!/usr/bin/env python3
"""Generate a direct qfasm2 fixture combining forwarding and dynamic atoms."""

from pathlib import Path

from generate_stage5_copy_dynamic_atom_cdr_gc import scan_cdr_field_dynamic_atoms
from generate_stage5_copy_dynamic_atoms_output_gc import init_atom, overwrite_old_cell
from generate_stage5_scan_forwarding_gc import cell, ins_block


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "bootstrap" / "stage5-scan-forwarding-dynamic-atom-gc.qf1"


def scan_car_forward_inline():
    return [
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(TestAlPair)",
        "(Jz HandleCarPair)",
        "(PopEax)",
        "(Jump FinishCar)",
        "(Label HandleCarPair)",
        "(PopEax)",
        "(PushEax)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 0F)",
        "(Jz UseForwardedCar)",
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
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxFromEbx)",
        "(AddEbxImm8 08)",
        "(MovEaxLabel HeapNext)",
        "(StoreDwordAtEaxFromEbx)",
        "(Jump FinishCar)",
        "(Label UseForwardedCar)",
        "(PopEax)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxFromEbx)",
        "(Label FinishCar)",
    ]


def scan_cdr_atom_inline():
    return [
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 01)",
        "(Jz FinishCdrAtom)",
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
        "(Label FinishCdrAtom)",
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


def check_heap_frontier():
    return [
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterPairs)",
        "(CmpEaxEbx)",
        "(Jz CheckAtomFrontier)",
        "(MovEbxImm32 03)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def check_atom_frontier():
    return [
        "(Label CheckAtomFrontier)",
        "(MovEaxLabel AtomNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterCopied)",
        "(CmpEaxEbx)",
        "(Jz CheckChildCycle)",
        "(MovEbxImm32 04)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def check_child_cycle():
    return [
        "(Label CheckChildCycle)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(LoadEaxCar)",
        "(PopEbx)",
        "(CmpEaxEbx)",
        "(Jz CheckCopiedAtomCdr)",
        "(MovEbxImm32 05)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def check_copied_atom_cdr():
    return [
        "(Label CheckCopiedAtomCdr)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(AndEaxNotTag)",
        "(CmpEaxLabel HeapAtomCdr)",
        "(Jz CheckCopiedAtomLength)",
        "(MovEbxImm32 06)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label CheckCopiedAtomLength)",
        "(MovEaxLabel HeapAtomCdr)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 02)",
        "(Jz ExitOk)",
        "(MovEbxImm32 07)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def main():
    instrs = [
        "(Label HeapNext)",
        "(DwordLabel HeapLimit)",
        "(Label AtomNext)",
        "(DwordLabel HeapAtomCdr)",
        "(Label Scan)",
        "(DwordLabel Heap)",
        "(Label Root)",
        "(DwordLabel OldRoot)",
        *cell("Heap"),
        *cell("HeapShared"),
        "(Label HeapAfterPairs)",
        *cell("HeapAtomCdr"),
        "(Label HeapAfterCopied)",
        "(Label HeapLimit)",
        "(Db 00)",
        "(Align4)",
        "(Label Chars41)",
        "(Db 34)",
        "(Db 31)",
        "(Align4)",
        *cell("OldAtomCdr"),
        "(Label OldRoot)",
        "(DwordLabel OldShared)",
        "(DwordNil)",
        "(Label OldShared)",
        "(DwordLabel OldShared)",
        "(DwordConst OldAtomCdr)",
        "(Align4)",
        "(Label Start)",
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
        "(Label ScanLoop)",
        *scan_car_forward_inline(),
        *scan_cdr_atom_inline(),
        *advance_scan_or_loop(),
        "(Label ScanDone)",
        *overwrite_old_cell("OldRoot"),
        *overwrite_old_cell("OldShared"),
        *overwrite_old_cell("OldAtomCdr"),
        *check_heap_frontier(),
        *check_atom_frontier(),
        *check_child_cycle(),
        *check_copied_atom_cdr(),
        "(Label ExitOk)",
        "(MovEbxImm32 00)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    text = """; Stage 5 scan-forwarding plus dynamic atom-copy fixture.
;
; Root points at one old child, and the old child points back to itself in its
; car while holding a runtime-initialized tagged atom in its cdr. Recovery
; copies the root, then scan-forwarding copies the child and uses the
; forwarding marker to rewrite the child's self-cycle. When the copied child is
; scanned, its cdr atom is copied into the atom frontier. Old root, child, and
; atom records are overwritten before the generated ELF verifies the copied
; cycle, pair and atom frontier positions, and copied atom length, then exits
; `0`.

(Assemble
  (Program
    Start
"""
    text += ins_block(instrs)
    text += "\n))\n"
    OUT.write_text(text)


if __name__ == "__main__":
    main()
