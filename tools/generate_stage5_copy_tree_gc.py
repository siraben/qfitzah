#!/usr/bin/env python3
"""Generate the direct qfasm2 Stage 5 tree-copy traversal fixture."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "bootstrap" / "stage5-copy-tree-gc.qf1"


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
        "(Label Scan)",
        "(DwordLabel Heap)",
        "(Label Root)",
        "(DwordLabel OldRoot)",
        *cell("Heap"),
        *cell("Heap1"),
        *cell("Heap2"),
        *cell("Heap3"),
        *cell("Heap4"),
        *cell("HeapAfterCopied"),
        "(Label HeapLimit)",
        "(Db 00)",
        "(Align4)",
        "(Label OldRoot)",
        "(DwordLabel OldLeft)",
        "(DwordLabel OldRight)",
        "(Label OldLeft)",
        "(DwordLabel OldLeafA)",
        "(Dword 01)",
        "(Label OldRight)",
        "(Dword 17)",
        "(DwordLabel OldLeafB)",
        "(Label OldLeafA)",
        "(Dword 13)",
        "(Dword 01)",
        "(Label OldLeafB)",
        "(Dword 23)",
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
        "(MovEbxLabel Heap1)",
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
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(TestAlPair)",
        "(Jz CopyCar)",
        "(PopEax)",
        "(Jump FinishCar)",
        "(Label CopyCar)",
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
        "(Label FinishCar)",
        "(MovEaxLabel Scan)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(PushEax)",
        "(TestAlPair)",
        "(Jz CopyCdr)",
        "(PopEax)",
        "(Jump FinishCdr)",
        "(Label CopyCdr)",
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
        "(Label FinishCdr)",
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
        "(Label ScanDone)",
        "(MovEaxLabel OldLeafA)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel OldLeafB)",
        "(MovEbxImm32 4D)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(MovEbxEax)",
        "(AddEbxImm8 08)",
        "(MovEaxLabel HeapNext)",
        "(StoreDwordAtEaxFromEbx)",
        "(PopEax)",
        "(MovEbxImm32 2A)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 01)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEbxCarFromEax)",
        "(CmpEbxImm8 13)",
        "(Jz CheckRightLeaf)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label CheckRightLeaf)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(LoadEaxCdr)",
        "(LoadEbxCarFromEax)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]

    text = """; Stage 5 pair-tree copy traversal fixture, direct qfasm2 source.
;
; HeapNext starts at HeapLimit to force recovery. Recovery copies Root to Heap,
; then scans copied pairs from Scan up to HeapNext. For each copied pair, any
; pair-valued car or cdr field is copied to HeapNext, the field is rewritten to
; the copied child, and HeapNext advances. This is an acyclic pair-tree
; traversal proof: it discovers nested pair fields instead of using a fixed
; object shape, but it does not preserve sharing or handle cycles yet.
;
; The old leaves are overwritten with 63 and 77 after traversal, then allocation
; resumes after the five copied cells. The generated ELF verifies the copied
; left leaf is still 19 and exits through the copied right leaf, 35.

(Assemble
  (Program
    Start
"""
    text += ins_block(instrs)
    text += "\n))\n"
    OUT.write_text(text)


if __name__ == "__main__":
    main()
