#!/usr/bin/env python3
"""Generate the qfc4-lifted Stage 5 GC plus content-checked byte output fixture."""

from pathlib import Path

from generate_stage5_copy_bytes_output_qfc4 import (
    data_cell,
    init_bytes_output_copy,
)
from generate_stage5_scan_forwarding_qfc4 import compile_rule, do_expr, qfc4_defs_block


ROOT = Path(__file__).resolve().parents[1]
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-copy-bytes-isbytes-output-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-copy-bytes-isbytes-output-gc-qfc4.qf1"


def finish_bytes_isbytes_output_copy():
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
        + do_expr(check_copied_bytes())
        + " "
        + do_expr(bad_status("03"))
        + ")",
    ]


def check_copied_bytes():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(Invoke IsBytes Empty)",
        "(IfZero IsBytesOk "
        + do_expr(emit_copied_byte())
        + " "
        + do_expr(bad_status("01"))
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
    qfc4 = [
        """; Optional qfc4 surface for GC plus content-checked byte-output fixture.

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
    for name in ["InitBytesOutputCopy", "FinishBytesIsBytesOutputCopy"]:
        qfc4.append(f"""(Rule
  (ParseStmt ({name}))
  {name})

""")
    for name, instrs in [
        ("InitBytesOutputCopy", init_bytes_output_copy()),
        ("FinishBytesIsBytesOutputCopy", finish_bytes_isbytes_output_copy()),
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
        "(Atom AtomNotSharedBytes BytesChars 05",
        "(String2 Chars41 34 31",
        "(Atom Atom41 Chars41 02",
        "(Pair OldBytesExpr (Const AtomNotSharedBytes) (Ptr OldBytesTail)",
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
                (FinishBytesIsBytesOutputCopy))))))""",
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
        """; Stage 5 GC plus content-checked byte-output fixture lifted through qfc4.
;
; Compile with qfc4-copy-bytes-isbytes-output-ext.qf1,
; qfc4-scan-copy-ext.qf1, qfasm-byte-output-ext.qf1, and the Stage 5 heap/scan
; extensions. The generated ELF copies `(Bytes 41)`, overwrites old pair
; objects, recognizes the copied head atom by contents, then emits byte `41`.

(QfcAssemble
  (Source
    Start
"""
        + qfc4_defs_block(defs)
        + "\n))\n"
    )


if __name__ == "__main__":
    main()
