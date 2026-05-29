#!/usr/bin/env python3
"""Generate a direct qfasm2 Stage 5 GC plus byte-output fixture."""

from pathlib import Path

from generate_stage5_copy_tree_gc import cell, ins_block


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "bootstrap" / "stage5-copy-bytes-output-gc.qf1"


def scan_car_field():
    return [
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
    ]


def scan_cdr_field():
    return [
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


def emit_byte_proc():
    return [
        "(Label EmitByte)",
        "(AndEaxNotTag)",
        "(LoadEcxCarFromEax)",
        "(LoadByteEbxFromEcx)",
        "(Call Nybble)",
        "(ShlEbxImm8 04)",
        "(PushEbx)",
        "(IncEcx)",
        "(LoadByteEbxFromEcx)",
        "(Call Nybble)",
        "(PopEcx)",
        "(OrEbxEcx)",
        "(PushEcx)",
        "(PushEdx)",
        "(PushEbx)",
        "(MovEaxImm32 04)",
        "(MovEbxImm32 01)",
        "(MovEcxEsp)",
        "(MovEdxImm32 01)",
        "(Int 80)",
        "(PopEbx)",
        "(PopEdx)",
        "(PopEcx)",
        "(Ret)",
    ]


def nybble_proc():
    return [
        "(Label Nybble)",
        "(SubEbxImm8 30)",
        "(CmpEbxImm8 09)",
        "(Jbe NybbleDone)",
        "(SubEbxImm8 07)",
        "(Label NybbleDone)",
        "(Ret)",
    ]


def main():
    instrs = [
        "(Label HeapNext)",
        "(DwordLabel HeapLimit)",
        "(Label Scan)",
        "(DwordLabel Heap)",
        "(Label Root)",
        "(DwordLabel OldBytesExpr)",
        *cell("Heap"),
        *cell("HeapTail"),
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
        "(Label AtomBytes)",
        "(DwordLabel BytesChars)",
        "(Dword 05)",
        "(Label Chars41)",
        "(Db 34)",
        "(Db 31)",
        "(Align4)",
        "(Label Atom41)",
        "(DwordLabel Chars41)",
        "(Dword 02)",
        "(Label OldBytesExpr)",
        "(DwordConst AtomBytes)",
        "(DwordLabel OldBytesTail)",
        "(Label OldBytesTail)",
        "(DwordConst Atom41)",
        "(DwordNil)",
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
        "(MovEbxLabel HeapTail)",
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
        *scan_cdr_field(),
        *advance_scan_or_loop(),
        "(Label ScanDone)",
        "(MovEaxLabel OldBytesExpr)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel OldBytesTail)",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterCopied)",
        "(CmpEaxEbx)",
        "(Jz EmitCopiedByte)",
        "(MovEbxImm32 03)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label EmitCopiedByte)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(LoadEaxCar)",
        "(Call EmitByte)",
        "(MovEbxImm32 00)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        *emit_byte_proc(),
        *nybble_proc(),
    ]

    text = """; Stage 5 GC plus byte-output fixture, direct qfasm2 source.
;
; HeapNext starts at HeapLimit to force recovery. Recovery copies a static
; Qfitzah object for `(Bytes 41)` into Heap, scans pair-valued fields from Scan
; to HeapNext, and then overwrites the old pair objects. The generated ELF runs
; the copied tail through the real EmitByte/Nybble/write path and writes byte
; `41` (`A`) to stdout, then exits 0.

(Assemble
  (Program
    Start
"""
    text += ins_block(instrs)
    text += "\n))\n"
    OUT.write_text(text)


if __name__ == "__main__":
    main()
