#!/usr/bin/env python3
"""Generate the qfc4-lifted Stage 5 GC plus byte-output fixture."""

from pathlib import Path

from generate_stage5_scan_forwarding_qfc4 import compile_rule, do_expr, qfc4_defs_block


ROOT = Path(__file__).resolve().parents[1]
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-copy-bytes-output-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-copy-bytes-output-gc-qfc4.qf1"


def data_cell(label):
    return [f"(Data {label} 00"] + [f"(Data {label}{n} 00" for n in range(1, 8)]


def init_bytes_output_copy():
    return [
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
    ]


def finish_bytes_output_copy():
    return [
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
        "(IfZero HeapNextOk "
        + do_expr(emit_copied_byte())
        + " "
        + do_expr(bad_status("03"))
        + ")",
    ]


def emit_copied_byte():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(LoadEaxCar)",
        "(Invoke EmitByte Empty)",
        "(MovEbxImm32 00)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def bad_status(value):
    return [
        f"(MovEbxImm32 {value})",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def main():
    names = [
        "InitBytesOutputCopy",
        "FinishBytesOutputCopy",
    ]

    qfc4 = ["; Optional qfc4 surface for GC plus byte-output fixture.\n\n"]
    for name in names:
        qfc4.append(f"""(Rule
  (ParseStmt ({name}))
  {name})

""")
    for name, instrs in [
        ("InitBytesOutputCopy", init_bytes_output_copy()),
        ("FinishBytesOutputCopy", finish_bytes_output_copy()),
    ]:
        qfc4.append(compile_rule(name, instrs))
        qfc4.append("\n")
    QFC4_EXT_OUT.write_text("".join(qfc4).rstrip() + "\n")

    defs = [
        "(PtrCell HeapNext HeapLimit",
        "(PtrCell Scan Heap",
        "(PtrCell Root OldBytesExpr",
        *data_cell("Heap"),
        *data_cell("HeapTail"),
        "(Data HeapAfterCopied 00",
        "(Data HeapLimit 00",
        "(String5 BytesChars 42 79 74 65 73",
        "(Atom AtomBytes BytesChars 05",
        "(String2 Chars41 34 31",
        "(Atom Atom41 Chars41 02",
        "(Pair OldBytesExpr (Const AtomBytes) (Ptr OldBytesTail)",
        "(Pair OldBytesTail (Const Atom41) Nil",
        """(Def
      Start
      NoFrame
      (Seq
        (InitBytesOutputCopy)
        (Seq
          (Local ScanLoop)
          (Seq
            (ScanCarField)
            (Seq
              (ScanCdrField)
              (Seq
                (AdvanceScanOrLoop ScanLoop)
                (FinishBytesOutputCopy))))))""",
        """(Def
      EmitByte
      NoFrame
      (Seq
        (LoadAtomCharsEcx)
        (Seq
          (LoadByteEbxFromEcx)
          (Seq
            (CallProc Nybble)
            (Seq
              (ShlEbx 04)
              (Seq
                (PushEbx)
                (Seq
                  (IncEcx)
                  (Seq
                    (LoadByteEbxFromEcx)
                    (Seq
                      (CallProc Nybble)
                      (Seq
                        (PopEcx)
                        (Seq
                          (OrEbxEcx)
                          (WriteByteFromEbx)))))))))))""",
        """(Def
      Nybble
      NoFrame
      (Seq
        (SubEbx 30)
        (Seq
          (CmpEbx 09)
          (IfBelowEq
            Done
            (Nop)
            (SubEbx 07))))""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 GC plus byte-output fixture lifted through qfc4.
;
; Compile with qfc4-copy-bytes-output-ext.qf1, qfc4-scan-copy-ext.qf1, and the
; Stage 5 heap/scan extensions. The generated ELF copies `(Bytes 41)` through
; the scan-copy recovery path, overwrites the old pair objects, then emits byte
; `41` from the copied graph.

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


if __name__ == "__main__":
    main()
