"""Shared qfc4 surface for checked root-table collector fixtures."""

from pathlib import Path

from generate_stage5_root_table_forwarding_qfc4 import bad_status
from generate_stage5_scan_forwarding_qfc4 import compile_rule, do_expr


ROOT = Path(__file__).resolve().parents[1]
QFC4_COMMON_OUT = ROOT / "bootstrap" / "qfc4-checked-root-table-common-ext.qf1"


def initial_checked_overflow():
    return [
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(MovEbxEax)",
        "(AddEbxImm8 08)",
        "(CmpEbxLabel HeapLimit)",
        "(IfBelowEq UnexpectedInitialCommit "
        + do_expr(bad_status("08"))
        + " (Do (JumpNear Recover) End))",
    ]


def commit_retry_body():
    return [
        "(MovEaxLabel HeapNext)",
        "(StoreDwordAtEaxFromEbx)",
        "(PopEax)",
        "(MovEbxImm32 2A)",
        "(StoreDwordAtEaxFromEbx)",
        "(MovEcxImm32 01)",
        "(StoreDwordAtEaxPlus4FromEcx)",
    ]


def retry_checked_allocation():
    return [
        "(MovEaxLabel HeapNext)",
        "(LoadEaxCar)",
        "(PushEax)",
        "(MovEbxEax)",
        "(AddEbxImm8 08)",
        "(CmpEbxLabel HeapLimit)",
        "(IfBelowEq CommitRetry "
        + do_expr(commit_retry_body())
        + " "
        + do_expr(bad_status("09"))
        + ")",
    ]


def write_checked_root_table_common_ext():
    names = [
        "InitialCheckedRootTableOverflow",
        "RetryCheckedRootTableAllocation",
    ]

    qfc4 = ["; Optional shared qfc4 surface for checked root-table collection.\n\n"]
    for name in names:
        qfc4.append(
            f"""(Rule
  (ParseStmt ({name}))
  {name})

"""
        )

    for name, instrs in [
        ("InitialCheckedRootTableOverflow", initial_checked_overflow()),
        ("RetryCheckedRootTableAllocation", retry_checked_allocation()),
    ]:
        qfc4.append(compile_rule(name, instrs))
        qfc4.append("\n")

    QFC4_COMMON_OUT.write_text("".join(qfc4).rstrip() + "\n")
