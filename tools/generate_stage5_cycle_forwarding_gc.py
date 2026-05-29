#!/usr/bin/env python3
"""Generate the direct qfasm2 Stage 5 cycle-forwarding GC fixture."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "bootstrap" / "stage5-forwarding-cycle-gc.qf1"


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
        "(Label HeapAfterCopied)",
        "(Label HeapLimit)",
        "(Db 00)",
        "(Align4)",
        "(Label OldRoot)",
        "(DwordLabel OldRoot)",
        "(Dword 17)",
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
        "(MovEbxLabel HeapAfterCopied)",
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
        "(MovEaxLabel OldRoot)",
        "(MovEbxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 0F)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel Heap)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(LoadEaxCdr)",
        "(CmpEaxImm8 0F)",
        "(Jz UseForwardedCar)",
        "(MovEbxImm32 02)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label UseForwardedCar)",
        "(PopEax)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(MovEaxLabel Heap)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel OldRoot)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(LoadEbxCarFromEax)",
        "(PopEax)",
        "(CmpEaxEbx)",
        "(Jz CheckCopiedCycle)",
        "(MovEbxImm32 01)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label CheckCopiedCycle)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(MovEbxEax)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    text = """; Stage 5 cycle-forwarding recovery fixture, direct qfasm2 source.
;
; Root points at OldRoot, and OldRoot's car points back to OldRoot. Recovery
; copies OldRoot once to Heap, marks OldRoot as forwarded to Heap, and resolves
; the copied car field through that forwarding marker so the copied object
; points to itself instead of to the old object.
;
; The old object is overwritten after forwarding. The generated ELF checks that
; the copied car is pointer-equal to the copied root, then exits through the
; copied self-cycle's cdr (`17`, status 23). A stale edge to OldRoot would exit
; through the overwritten cdr (`4D`, status 77).

(Assemble
  (Program
    Start
"""
    text += ins_block(instrs)
    text += "\n))\n"
    OUT.write_text(text)


if __name__ == "__main__":
    main()
