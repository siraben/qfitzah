#!/usr/bin/env python3
"""Generate checked allocation plus scan-forwarding dynamic atom GC fixture."""

from pathlib import Path

from generate_stage5_copy_dynamic_atoms_output_gc import init_atom, overwrite_old_cell
from generate_stage5_scan_forwarding_dynamic_atom_gc import (
    advance_scan_or_loop,
    check_atom_frontier,
    check_child_cycle,
    check_copied_atom_cdr,
    scan_car_forward_inline,
    scan_cdr_atom_inline,
)
from generate_stage5_scan_forwarding_gc import cell, ins_block


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "bootstrap" / "stage5-checked-scan-forwarding-dynamic-atom-gc.qf1"


def initial_overflow_check():
    return [
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(MovEbxEax)",
        "(AddEbxImm8 08)",
        "(CmpEbxLabel HeapLimit)",
        "(Jbe UnexpectedInitialCommit)",
        "(Jump Recover)",
        "(Label UnexpectedInitialCommit)",
        "(MovEbxImm32 08)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def recover_live_graph():
    return [
        "(Label Recover)",
        "(PopEax)",
        "(MovEaxLabel AtomNext)",
        "(MovEbxLabel HeapAtomCdr)",
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


def retry_checked_allocation():
    return [
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(MovEbxEax)",
        "(AddEbxImm8 08)",
        "(CmpEbxLabel HeapLimit)",
        "(Jbe CommitRetry)",
        "(MovEbxImm32 09)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label CommitRetry)",
        "(MovEaxLabel HeapNext)",
        "(StoreDwordAtEaxFromEbx)",
        "(PopEax)",
        "(MovEbxImm32 2A)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 01)",
        "(StoreDwordAtEaxPlus4FromEcx)",
    ]


def check_heap_frontier_after_retry():
    return [
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterRetry)",
        "(CmpEaxEbx)",
        "(Jz CheckAtomFrontier)",
        "(MovEbxImm32 03)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def check_retry_pair():
    return [
        "(Label CheckRetryPair)",
        "(MovEaxLabel HeapRetry)",
        "(LoadEaxCar)",
        "(CmpEaxImm8 2A)",
        "(Jz CheckRetryNil)",
        "(MovEbxImm32 0A)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label CheckRetryNil)",
        "(MovEaxLabel HeapRetry)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 01)",
        "(Jz ExitOk)",
        "(MovEbxImm32 0B)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def retarget_copied_atom_check():
    instrs = []
    for instr in check_copied_atom_cdr():
        if instr == "(Jz ExitOk)":
            instrs.append("(Jz CheckRetryPair)")
        else:
            instrs.append(instr)
    return instrs


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
        *cell("HeapRetry"),
        "(Label HeapAfterRetry)",
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
        *initial_overflow_check(),
        *recover_live_graph(),
        "(Label ScanLoop)",
        *scan_car_forward_inline(),
        *scan_cdr_atom_inline(),
        *advance_scan_or_loop(),
        "(Label ScanDone)",
        *retry_checked_allocation(),
        *overwrite_old_cell("OldRoot"),
        *overwrite_old_cell("OldShared"),
        *overwrite_old_cell("OldAtomCdr"),
        *check_heap_frontier_after_retry(),
        *check_atom_frontier(),
        *check_child_cycle(),
        *retarget_copied_atom_check(),
        *check_retry_pair(),
        "(Label ExitOk)",
        "(MovEbxImm32 00)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    text = """; Stage 5 checked allocation plus scan-forwarding dynamic atom GC.
;
; HeapNext starts at HeapLimit, so the first checked pair allocation must take
; the overflow path. Recovery copies the live root, scan-forwarding copies a
; self-cyclic child, and the child's runtime-initialized cdr atom is copied
; into a separate atom frontier. The allocator then retries, stores a fresh
; pair after the copied pair graph, overwrites all old records, verifies the
; copied cycle and atom plus the retry allocation, and exits `0`.

(Assemble
  (Program
    Start
"""
    text += ins_block(instrs)
    text += "\n))\n"
    OUT.write_text(text)


if __name__ == "__main__":
    main()
