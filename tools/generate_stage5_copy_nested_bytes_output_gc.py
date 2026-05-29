#!/usr/bin/env python3
"""Generate a direct qfasm2 Stage 5 GC plus nested byte-output fixture."""

from pathlib import Path

from generate_stage5_copy_bytes_isbytes_output_gc import is_bytes_proc, nybble_proc
from generate_stage5_copy_bytes_output_gc import (
    advance_scan_or_loop,
    emit_byte_proc,
    scan_car_field,
    scan_cdr_field,
)
from generate_stage5_copy_tree_gc import cell, ins_block


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "bootstrap" / "stage5-copy-nested-bytes-output-gc.qf1"


def emit_bytes_proc():
    return [
        "(Label EmitBytes)",
        "(TestAlPair)",
        "(Jz EmitBytesCons)",
        "(Ret)",
        "(Label EmitBytesCons)",
        "(PushEax)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(Call IsBytes)",
        "(Jz EmitBytesNested)",
        "(PopEax)",
        "(Call EmitByte)",
        "(PopEax)",
        "(LoadEaxCdr)",
        "(Call EmitBytes)",
        "(Ret)",
        "(Label EmitBytesNested)",
        "(PopEax)",
        "(LoadEaxCdr)",
        "(Call EmitBytes)",
        "(PopEax)",
        "(LoadEaxCdr)",
        "(Call EmitBytes)",
        "(Ret)",
    ]


def overwrite_old_pair(label):
    return [
        f"(MovEaxLabel {label})",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
    ]


def main():
    instrs = [
        "(Label HeapNext)",
        "(DwordLabel HeapLimit)",
        "(Label Scan)",
        "(DwordLabel Heap)",
        "(Label Root)",
        "(DwordLabel OldBytesOuter)",
        *cell("Heap"),
        *cell("HeapOuterTail"),
        *cell("HeapInner"),
        *cell("HeapInnerTail"),
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
        "(Label AtomOuterBytes)",
        "(DwordLabel BytesChars)",
        "(Dword 05)",
        "(Label AtomInnerBytes)",
        "(DwordLabel BytesChars)",
        "(Dword 05)",
        "(Label Chars41)",
        "(Db 34)",
        "(Db 31)",
        "(Align4)",
        "(Label Atom41)",
        "(DwordLabel Chars41)",
        "(Dword 02)",
        "(Label OldBytesOuter)",
        "(DwordConst AtomOuterBytes)",
        "(DwordLabel OldOuterTail)",
        "(Label OldOuterTail)",
        "(DwordLabel OldBytesInner)",
        "(DwordNil)",
        "(Label OldBytesInner)",
        "(DwordConst AtomInnerBytes)",
        "(DwordLabel OldInnerTail)",
        "(Label OldInnerTail)",
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
        "(MovEbxLabel HeapOuterTail)",
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
        *overwrite_old_pair("OldBytesOuter"),
        *overwrite_old_pair("OldOuterTail"),
        *overwrite_old_pair("OldBytesInner"),
        *overwrite_old_pair("OldInnerTail"),
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterCopied)",
        "(CmpEaxEbx)",
        "(Jz EmitCopiedBytes)",
        "(MovEbxImm32 03)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        "(Label EmitCopiedBytes)",
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(Call EmitBytes)",
        "(MovEbxImm32 00)",
        "(MovEaxImm32 01)",
        "(Int 80)",
        *emit_bytes_proc(),
        *is_bytes_proc(),
        *emit_byte_proc(),
        *nybble_proc(),
    ]

    text = """; Stage 5 GC plus nested byte-output fixture, direct qfasm2 source.
;
; HeapNext starts at HeapLimit to force recovery. Recovery copies a static
; Qfitzah object for `(Bytes (Bytes 41))` into Heap, scans pair-valued fields
; from Scan to HeapNext, and overwrites all old pair objects. The generated ELF
; then runs content-based IsBytes inside EmitBytes, flattens the copied nested
; Bytes object, writes byte `41` (`A`) to stdout, and exits 0.

(Assemble
  (Program
    Start
"""
    text += ins_block(instrs)
    text += "\n))\n"
    OUT.write_text(text)


if __name__ == "__main__":
    main()
