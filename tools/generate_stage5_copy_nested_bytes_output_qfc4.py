#!/usr/bin/env python3
"""Generate the qfc4-lifted Stage 5 GC plus nested byte output fixture."""

from pathlib import Path

from generate_stage5_copy_bytes_output_qfc4 import data_cell
from generate_stage5_scan_forwarding_qfc4 import compile_rule, do_expr, qfc4_defs_block


ROOT = Path(__file__).resolve().parents[1]
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-copy-nested-bytes-output-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-copy-nested-bytes-output-gc-qfc4.qf1"


def init_nested_bytes_output_copy():
    return [
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
    ]


def overwrite_old_pair(label):
    return [
        f"(MovEaxLabel {label})",
        "(MovEbxImm32 3F)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 4D)",
        "(StoreDwordAtEaxPlus4FromEcx)",
    ]


def finish_nested_bytes_output_copy():
    return [
        *overwrite_old_pair("OldBytesOuter"),
        *overwrite_old_pair("OldOuterTail"),
        *overwrite_old_pair("OldBytesInner"),
        *overwrite_old_pair("OldInnerTail"),
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterCopied)",
        "(CmpEaxEbx)",
        "(IfZero HeapNextOk "
        + do_expr(emit_copied_bytes())
        + " "
        + do_expr(bad_status("03"))
        + ")",
    ]


def emit_copied_bytes():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(Invoke EmitBytes Empty)",
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


def write_qfc4_extension():
    qfc4 = [
        """; Optional qfc4 surface for recovered nested byte-output fixture.

(Rule
  (ParseStmt (JumpLocal name))
  (JumpLocal name))

(Rule
  (ParseStmt (JumpNotZeroLocal name))
  (JumpNotZeroLocal name))

(Rule
  (ParseStmt (UntagEax))
  UntagEax)

(Rule
  (ParseStmt (CmpDwordAtEax b1 b2 b3 b4))
  (CmpDwordAtEax b1 b2 b3 b4))

(Rule
  (ParseStmt (CmpByteAtEaxPlus4 byte))
  (CmpByteAtEaxPlus4 byte))

(Rule
  (CompileStmt (JumpLocal name))
  (Do (JumpLocal name) End))

(Rule
  (CompileStmt (JumpNotZeroLocal name))
  (Do (JumpNotZeroLocal name) End))

(Rule
  (CompileStmt UntagEax)
  (Do (AndEaxNotTag) End))

(Rule
  (CompileStmt (CmpDwordAtEax b1 b2 b3 b4))
  (Do (CmpDwordAtEaxImm32 b1 b2 b3 b4) End))

(Rule
  (CompileStmt (CmpByteAtEaxPlus4 byte))
  (Do (CmpByteAtEaxPlus4Imm8 byte) End))

"""
    ]
    for name in ["InitNestedBytesOutputCopy", "FinishNestedBytesOutputCopy"]:
        qfc4.append(
            f"""(Rule
  (ParseStmt ({name}))
  {name})

"""
        )
    for name, instrs in [
        ("InitNestedBytesOutputCopy", init_nested_bytes_output_copy()),
        ("FinishNestedBytesOutputCopy", finish_nested_bytes_output_copy()),
    ]:
        qfc4.append(compile_rule(name, instrs))
        qfc4.append("\n")
    QFC4_EXT_OUT.write_text("".join(qfc4).rstrip() + "\n")


def write_qfc4_source():
    defs = [
        "(PtrCell HeapNext HeapLimit",
        "(PtrCell Scan Heap",
        "(PtrCell Root OldBytesOuter",
        *data_cell("Heap"),
        *data_cell("HeapOuterTail"),
        *data_cell("HeapInner"),
        *data_cell("HeapInnerTail"),
        "(Data HeapAfterCopied 00",
        "(Data HeapLimit 00",
        "(String5 BytesChars 42 79 74 65 73",
        "(Atom AtomOuterBytes BytesChars 05",
        "(Atom AtomInnerBytes BytesChars 05",
        "(String2 Chars41 34 31",
        "(Atom Atom41 Chars41 02",
        "(Pair OldBytesOuter (Const AtomOuterBytes) (Ptr OldOuterTail)",
        "(Pair OldOuterTail (Ptr OldBytesInner) Nil",
        "(Pair OldBytesInner (Const AtomInnerBytes) (Ptr OldInnerTail)",
        "(Pair OldInnerTail (Const Atom41) Nil",
        """(Def
      Start
      NoFrame
      (Seq
        (InitNestedBytesOutputCopy)
        (Seq
          (Local ScanLoop)
          (Seq
            (ScanCarField)
            (Seq
              (ScanCdrField)
              (Seq
                (AdvanceScanOrLoop ScanLoop)
                (FinishNestedBytesOutputCopy))))))""",
        """(Def
      IsBytes
      NoFrame
      (Seq
        (TestPairEax)
        (Seq
          (JumpNotZeroLocal IsBytesNo)
          (Seq
            (CarEax)
            (Seq
              (UntagEax)
              (Seq
                (PushEax)
                (Seq
                  (CdrEax)
                  (Seq
                    (CmpEax 05)
                    (Seq
                      (JumpNotZeroLocal IsBytesNoPop)
                      (Seq
                        (PopEax)
                        (Seq
                          (CarEax)
                          (Seq
                            (CmpDwordAtEax 42 79 74 65)
                            (Seq
                              (JumpNotZeroLocal IsBytesNo)
                              (Seq
                                (CmpByteAtEaxPlus4 73)
                                (Seq
                                  (JumpLocal IsBytesDone)
                                  (Seq
                                    (Local IsBytesNoPop)
                                    (Seq
                                      (PopEax)
                                      (Seq
                                        (Local IsBytesNo)
                                        (Seq
                                          (CmpEax 00)
                                          (Local IsBytesDone)))))))))))))))))))""",
        """(Def
      EmitBytes
      NoFrame
      (Seq
        (TestPairEax)
        (IfZero
          Cons
          (Seq
            (PushEax)
            (Seq
              (CarEax)
              (Seq
                (PushEax)
                (Seq
                  (CallProc IsBytes)
                  (IfZero
                    Nested
                    (Seq
                      (PopEax)
                      (Seq
                        (CdrEax)
                        (Seq
                          (CallProc EmitBytes)
                          (Seq
                            (PopEax)
                            (Seq
                              (CdrEax)
                              (Seq
                                (CallProc EmitBytes)
                                (Return)))))))
                    (Seq
                      (PopEax)
                      (Seq
                        (CallProc EmitByte)
                        (Seq
                          (PopEax)
                          (Seq
                            (CdrEax)
                            (Seq
                              (CallProc EmitBytes)
                              (Return)))))))))))
          (Return)))""",
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
        """; Stage 5 GC plus nested byte-output fixture lifted through qfc4.
;
; Compile with qfc4-copy-nested-bytes-output-ext.qf1,
; qfc4-scan-copy-ext.qf1, qfasm-byte-output-ext.qf1, and the Stage 5 heap/scan
; extensions. The generated ELF copies `(Bytes (Bytes 41))`, overwrites old
; pair objects, recognizes both copied `Bytes` atoms by contents, then flattens
; the nested byte stream to stdout byte `41`.

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


def main():
    write_qfc4_extension()
    write_qfc4_source()


if __name__ == "__main__":
    main()
