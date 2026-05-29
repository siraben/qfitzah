#!/usr/bin/env python3
"""Generate the direct qfasm2 Stage 5 forwarding-pointer GC fixture."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "bootstrap" / "stage5-forwarding-gc.qf1"


def cell(label):
    return [f"(Label {label})"] + ["(Db 00)"] * 8


def ins_block(instrs):
    lines = []
    indent = "    "
    for instr in instrs:
        lines.append(f"{indent}(Ins {instr}")
    lines.append(f"{indent}End" + ")" * len(instrs))
    return "\n".join(lines)


def main():
    instrs = [
        "(Label HeapNext)",
        "(DwordLabel HeapLimit)",
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
        "(Dword 01)",
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
        "(MovEaxLabel Heap)",
        "(LoadEaxCar)",
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
        "(MovEaxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(AddEbxImm8 08)",
        "(MovEaxLabel HeapNext)",
        "(StoreDwordAtEaxFromEbx)",
        "(Jump FinishCar)",
        "(Label UseForwardedCar)",
        "(PopEax)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(Label FinishCar)",
        "(MovEaxLabel Heap)",
        "(LoadEaxCdr)",
        "(PushEax)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 0F)",
        "(Jz UseForwardedCdr)",
        "(MovEbxImm32 02)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label UseForwardedCdr)",
        "(PopEax)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEcxEbx)",
        "(MovEaxLabel Heap)",
        "(StoreDwordAtEaxPlus4FromEcx)",
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
        "(Jz CheckHeapNext)",
        "(MovEbxImm32 01)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label CheckHeapNext)",
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterCopied)",
        "(CmpEaxEbx)",
        "(Jz CheckCopiedChild)",
        "(MovEbxImm32 02)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label CheckCopiedChild)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEbxCarFromEax)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    text = """; Stage 5 forwarding-pointer recovery fixture, direct qfasm2 source.
;
; Root has two fields that both point at OldShared. Recovery copies Root to
; Heap, copies OldShared once to HeapChild, then installs a temporary
; forwarding marker in OldShared: car holds the copied pointer and cdr holds
; marker 0F. The second edge recognizes that marker and reuses the forwarded
; pointer instead of copying OldShared again.
;
; After both fields are rewritten, the old shared object is overwritten. The
; generated ELF checks that the copied root's car and cdr are pointer-equal,
; that HeapNext advanced by only two cells, and then exits with the copied
; child car, 19. This proves sharing preservation for one acyclic shared pair;
; it is not a full general forwarding-object representation yet.

(Assemble
  (Program
    Start
"""
    text += ins_block(instrs)
    text += "\n))\n"
    OUT.write_text(text)


if __name__ == "__main__":
    main()
