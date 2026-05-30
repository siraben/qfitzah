#!/usr/bin/env python3
"""Generate the direct qfasm2 Stage 5 multi-root forwarding GC fixture."""

from pathlib import Path

from generate_stage5_scan_forwarding_gc import (
    cell,
    copy_or_forward_car,
    copy_or_forward_cdr,
    ins_block,
)


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "bootstrap" / "stage5-multi-root-forwarding-gc.qf1"


def fail(status):
    return [
        f"(MovEbxImm32 {status})",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def main():
    instrs = [
        "(Label HeapNext)",
        "(DwordLabel HeapLimit)",
        "(Label Scan)",
        "(DwordLabel Heap)",
        "(Label RootA)",
        "(DwordLabel OldRoot)",
        "(Label RootB)",
        "(DwordLabel OldRoot)",
        *cell("Heap"),
        *cell("HeapChild"),
        "(Label HeapAfterCopied)",
        "(Label HeapLimit)",
        "(Db 00)",
        "(Align4)",
        "(Label OldRoot)",
        "(DwordLabel OldChild)",
        "(DwordLabel OldChild)",
        "(Label OldChild)",
        "(Dword 13)",
        "(DwordLabel OldChild)",
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
        *fail("07"),
        "(Label Recover)",
        "(PopEax)",
        "(MovEaxLabel RootA)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(LoadEbxCarFromEax)",
        "(LoadEcxCdrFromEax)",
        "(MovEaxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(PopEax)",
        "(MovEbxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 0F)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel RootA)",
        "(MovEbxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapChild)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel RootB)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 0F)",
        "(Jz UseForwardedRootB)",
        *fail("04"),
        "(Label UseForwardedRootB)",
        "(PopEax)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel RootB)",
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
        "(MovEaxLabel OldRoot)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel OldChild)",
        "(MovEbxImm32 5E)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 6F)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel RootA)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel RootB)",
        "(LoadEaxCar)",
        "(CmpEaxEbx)",
        "(Jz CheckRootSharing)",
        *fail("01"),
        "(Label CheckRootSharing)",
        "(MovEaxLabel RootA)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(MovEaxLabel RootA)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(PopEbx)",
        "(CmpEaxEbx)",
        "(Jz CheckChildCycle)",
        *fail("02"),
        "(Label CheckChildCycle)",
        "(MovEaxLabel RootA)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(LoadEaxCdr)",
        "(PopEbx)",
        "(CmpEaxEbx)",
        "(Jz CheckHeapNext)",
        *fail("03"),
        "(Label CheckHeapNext)",
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterCopied)",
        "(CmpEaxEbx)",
        "(Jz ExitCopiedChild)",
        *fail("05"),
        "(Label ExitCopiedChild)",
        "(MovEaxLabel RootB)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEbxCarFromEax)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    text = """; Stage 5 multi-root scan-forwarding recovery fixture, direct qfasm2 source.
;
; RootA and RootB both start at OldRoot. Recovery copies OldRoot once, marks it
; forwarded, updates RootA, then updates RootB through the forwarding marker
; instead of copying OldRoot again. The scan loop then copies OldRoot's shared
; cyclic child once, rewrites both copied root fields and the child's self-edge,
; and advances HeapNext by exactly two cells.
;
; OldRoot and OldChild are overwritten after recovery. The generated ELF checks
; that both root slots point at the same copied root, that the copied root's two
; fields share the same copied child, that the child points to itself, and that
; HeapNext reached HeapAfterCopied. It exits with the copied child car (`13`,
; status 19).

(Assemble
  (Program
    Start
"""
    text += ins_block(instrs)
    text += "\n))\n"
    OUT.write_text(text)


if __name__ == "__main__":
    main()
