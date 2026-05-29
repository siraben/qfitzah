#!/usr/bin/env python3
"""Generate the qfc4-lifted deep dynamic atom-copy fixture."""

from pathlib import Path

from generate_stage5_copy_bytes_output_qfc4 import data_cell
from generate_stage5_copy_dynamic_atom_cdr_gc import scan_cdr_field_dynamic_atoms
from generate_stage5_copy_dynamic_atoms_output_gc import init_atom, overwrite_old_cell
from generate_stage5_scan_forwarding_qfc4 import compile_rule, do_expr, qfc4_defs_block


ROOT = Path(__file__).resolve().parents[1]
QFC4_EXT_OUT = ROOT / "bootstrap" / "qfc4-copy-dynamic-atom-deep-ext.qf1"
QFC4_SRC_OUT = ROOT / "bootstrap" / "stage5-copy-dynamic-atom-deep-gc-qfc4.qf1"


def bad_status(value):
    return [
        f"(MovEbxImm32 {value})",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def init_dynamic_atom_deep_copy():
    return [
        *init_atom("OldAtomCdr", "Chars41", "02"),
        "(MovEaxLabel HeapNext)",
        "(MovEbxLabel HeapChild)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEaxLabel AtomNext)",
        "(MovEbxLabel HeapAtomCdr)",
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


def dynamic_atom_deep_loop():
    return [
        "(Label ScanLoop)",
    ]


def advance_dynamic_atom_deep_loop():
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


def check_copied_child():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(CmpEaxLabel HeapChild)",
        "(IfZero CheckCopiedGrandchild "
        + do_expr([])
        + " "
        + do_expr(bad_status("02"))
        + ")",
    ]


def check_copied_grandchild():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(CmpEaxLabel HeapGrandchild)",
        "(IfZero CheckAtomNext "
        + do_expr([])
        + " "
        + do_expr(bad_status("05"))
        + ")",
    ]


def check_copied_grandchild_cdr():
    return [
        "(MovEaxLabel Root)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCar)",
        "(LoadEaxCdr)",
        "(AndEaxNotTag)",
        "(CmpEaxLabel HeapAtomCdr)",
        "(IfZero ExitOk " + do_expr([]) + " " + do_expr(bad_status("06")) + ")",
    ]


def finish_dynamic_atom_deep_copy():
    return [
        *overwrite_old_cell("OldRoot"),
        *overwrite_old_cell("OldChild"),
        *overwrite_old_cell("OldGrandchild"),
        *overwrite_old_cell("OldAtomCdr"),
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterPairs)",
        "(CmpEaxEbx)",
        "(IfZero CheckCopiedChild " + do_expr([]) + " " + do_expr(bad_status("03")) + ")",
        *check_copied_child(),
        *check_copied_grandchild(),
        "(MovEaxLabel AtomNext)",
        "(LoadEaxCar)",
        "(MovEbxLabel HeapAfterCopied)",
        "(CmpEaxEbx)",
        "(IfZero CheckCopiedCdr " + do_expr([]) + " " + do_expr(bad_status("04")) + ")",
        *check_copied_grandchild_cdr(),
        "(MovEbxImm32 00)",
        "(MovEaxImm32 01)",
        "(Int 80)",
    ]


def write_qfc4_extension():
    names = [
        "InitDynamicAtomDeepCopy",
        "DynamicAtomDeepLoop",
        "ScanDynamicAtomCdr",
        "AdvanceDynamicAtomDeepLoop",
        "FinishDynamicAtomDeepCopy",
    ]

    qfc4 = ["; Optional qfc4 surface for deep dynamic atom-copy fixture.\n\n"]
    for name in names:
        qfc4.append(
            f"""(Rule
  (ParseStmt ({name}))
  {name})

"""
        )

    for name, instrs in [
        ("InitDynamicAtomDeepCopy", init_dynamic_atom_deep_copy()),
        ("DynamicAtomDeepLoop", dynamic_atom_deep_loop()),
        ("ScanDynamicAtomCdr", scan_cdr_field_dynamic_atoms()),
        ("AdvanceDynamicAtomDeepLoop", advance_dynamic_atom_deep_loop()),
        ("FinishDynamicAtomDeepCopy", finish_dynamic_atom_deep_copy()),
    ]:
        qfc4.append(compile_rule(name, instrs))
        qfc4.append("\n")

    QFC4_EXT_OUT.write_text("".join(qfc4).rstrip() + "\n")


def write_qfc4_source():
    defs = [
        "(PtrCell HeapNext HeapLimit",
        "(PtrCell AtomNext HeapAtomCdr",
        "(PtrCell Scan Heap",
        "(PtrCell Root OldRoot",
        *data_cell("Heap"),
        *data_cell("HeapChild"),
        *data_cell("HeapGrandchild"),
        "(Data HeapAfterPairs 00",
        "(RawPair HeapAtomCdr 00 00",
        "(Data HeapAfterCopied 00",
        "(Data HeapLimit 00",
        "(String2 Chars41 34 31",
        "(RawPair OldAtomCdr 00 00",
        "(Pair OldRoot (Ptr OldChild) Nil",
        "(Pair OldChild (Ptr OldGrandchild) Nil",
        "(Pair OldGrandchild Nil (Const OldAtomCdr)",
        """(Def
      Start
      NoFrame
      (Seq
        (InitDynamicAtomDeepCopy)
        (Seq
          (DynamicAtomDeepLoop)
          (Seq
            (ScanCarField)
            (Seq
              (ScanDynamicAtomCdr)
              (Seq
                (AdvanceDynamicAtomDeepLoop)
                (FinishDynamicAtomDeepCopy))))))""",
    ]

    QFC4_SRC_OUT.write_text(
        """; Stage 5 deep dynamic atom-copy fixture lifted through qfc4.
;
; Recovery copies a root pair, then the scan loop discovers a child pair and a
; grandchild pair on successive scan iterations. The grandchild's runtime
; initialized tagged cdr atom is copied only after that grandchild is reached
; by traversal. The generated ELF overwrites all old records, verifies the
; copied pair chain and copied atom cdr, and exits `0`.

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
