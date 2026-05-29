#!/usr/bin/env python3
"""Generate the direct qfasm2 Stage 5 scan-forwarding GC fixture."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "bootstrap" / "stage5-scan-forwarding-gc.qf1"


def cell(label):
    return [f"(Label {label})"] + ["(Db 00)"] * 8


def ins_block(instrs):
    lines = []
    indent = "    "
    for instr in instrs:
        lines.append(f"{indent}(Ins {instr}")
    lines.append(f"{indent}End" + ")" * len(instrs))
    return "\n".join(lines)


def copy_or_forward_car():
    return [
        "(Label ScanCar)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(TestAlPair)",
        "(Jz HandleCarPair)",
        "(PopEax)",
        "(Ret)",
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
        "(Ret)",
        "(Label UseForwardedCar)",
        "(PopEax)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxFromEbx)",
        "(Ret)",
    ]


def copy_or_forward_cdr():
    return [
        "(Label ScanCdr)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(PushEax)",
        "(TestAlPair)",
        "(Jz HandleCdrPair)",
        "(PopEax)",
        "(Ret)",
        "(Label HandleCdrPair)",
        "(PopEax)",
        "(PushEax)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 0F)",
        "(Jz UseForwardedCdr)",
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
        "(MovEcxEbx)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(AddEbxImm8 08)",
        "(MovEaxLabel HeapNext)",
        "(StoreDwordAtEaxFromEbx)",
        "(Ret)",
        "(Label UseForwardedCdr)",
        "(PopEax)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEcxEbx)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(Ret)",
    ]


def main():
    instrs = [
        "(Label HeapNext)",
        "(DwordLabel HeapLimit)",
        "(Label Scan)",
        "(DwordLabel Heap)",
        "(Label Root)",
        "(DwordLabel OldRoot)",
        *cell("Heap"),
        *cell("HeapChild"),
        "(Label HeapAfterCopied)",
        "(Label HeapLimit)",
        "(Db 00)",
        "(Align4)",
        "(Label OldRoot)",
        "(DwordLabel OldShared)",
        "(DwordLabel OldShared)",
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
        "(MovEbxLabel HeapChild)",
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
        "(MovEaxLabel OldShared)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(CmpEaxEbx)",
        "(Jz CheckChildCycle)",
        "(MovEbxImm32 01)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label CheckChildCycle)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
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
        "(Jz ExitCopiedChild)",
        "(MovEbxImm32 03)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label ExitCopiedChild)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEbxCarFromEax)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    text = """; Stage 5 scan-forwarding recovery fixture, direct qfasm2 source.
;
; Root has two fields that both point at OldShared, and OldShared's cdr points
; back to OldShared. Recovery copies Root to Heap, then scans copied cells from
; Scan to HeapNext. When a pair field is first copied, the old pair is marked
; with a temporary forwarding pointer/marker. Later edges to that old pair,
; including OldShared's self-cycle, reuse the forwarded copy instead of copying
; again or leaving stale old pointers.
;
; After the scan, OldShared is overwritten. The generated ELF checks that the
; copied root preserves sharing, the copied child points to itself, HeapNext
; advanced by only two cells, and then exits with the copied child car (`13`,
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
