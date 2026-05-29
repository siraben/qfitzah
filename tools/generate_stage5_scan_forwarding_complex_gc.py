#!/usr/bin/env python3
"""Generate a larger direct qfasm2 Stage 5 scan-forwarding GC fixture."""

from pathlib import Path

from generate_stage5_scan_forwarding_gc import (
    cell,
    copy_or_forward_car,
    copy_or_forward_cdr,
    ins_block,
)


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "bootstrap" / "stage5-scan-forwarding-complex-gc.qf1"


def main():
    instrs = [
        "(Label HeapNext)",
        "(DwordLabel HeapLimit)",
        "(Label Scan)",
        "(DwordLabel Heap)",
        "(Label Root)",
        "(DwordLabel OldRoot)",
        *cell("Heap"),
        *cell("HeapLeft"),
        *cell("HeapRight"),
        *cell("HeapShared"),
        "(Label HeapAfterCopied)",
        "(Label HeapLimit)",
        "(Db 00)",
        "(Align4)",
        "(Label OldRoot)",
        "(DwordLabel OldLeft)",
        "(DwordLabel OldRight)",
        "(Label OldLeft)",
        "(Dword 11)",
        "(DwordLabel OldShared)",
        "(Label OldRight)",
        "(DwordLabel OldShared)",
        "(Dword 25)",
        "(Label OldShared)",
        "(Dword 13)",
        "(DwordLabel OldShared)",
        "(Align4)",
        "(Label Start)",
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(PushEax)",
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
        "(PopEax)",
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapLeft)",
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
        "(Call ScanCar)",
        "(Call ScanCdr)",
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
        "(JumpNear ScanDone)",
        *copy_or_forward_car(),
        *copy_or_forward_cdr(),
        "(Label ScanDone)",
        "(MovEaxLabel OldLeft)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel OldRight)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel OldShared)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(PushEax)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(LoadEaxCar)",
        "(PopEbx)",
        "(CmpEaxEbx)",
        "(Jz CheckSharedCycle)",
        "(MovEbxImm32 01)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label CheckSharedCycle)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(PushEax)",
        "(LoadEaxCdr)",
        "(PopEbx)",
        "(CmpEaxEbx)",
        "(Jz CheckHeapNext)",
        "(MovEbxImm32 02)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label CheckHeapNext)",
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterCopied)",
        "(CmpEaxEbx)",
        "(Jz ExitCopiedShared)",
        "(MovEbxImm32 03)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label ExitCopiedShared)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(LoadEbxCarFromEax)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    text = """; Stage 5 complex scan-forwarding recovery fixture, direct qfasm2 source.
;
; Root points at OldLeft and OldRight. OldLeft's cdr and OldRight's car both
; point at OldShared, and OldShared's cdr points back to itself. Recovery copies
; Root into Heap and then scans copied pairs from Scan to HeapNext, copying
; pair-valued fields once and using forwarding markers for later references.
;
; After the scan, all old objects are overwritten. The generated ELF checks
; that both paths still converge on the same copied shared node, that the
; copied shared node keeps its self-cycle, that HeapNext advanced by exactly
; four cells, and then exits with the copied shared car (`13`, status 19).

(Assemble
  (Program
    Start
"""
    text += ins_block(instrs)
    text += "\n))\n"
    OUT.write_text(text)


if __name__ == "__main__":
    main()
