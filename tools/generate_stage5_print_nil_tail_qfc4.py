#!/usr/bin/env python3
"""Generate qfc4 normal-printer nil plus recursive-list fixtures."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QFASM_TAIL_EXT_OUT = ROOT / "bootstrap" / "qfasm-print-n272-ext.qf1"
QFASM_NESTED_EXT_OUT = ROOT / "bootstrap" / "qfasm-print-n280-ext.qf1"
QFC4_TAIL_SRC_OUT = ROOT / "bootstrap" / "stage5-print-nil-and-list-tail-qfc4.qf1"
QFC4_NESTED_SRC_OUT = ROOT / "bootstrap" / "stage5-print-nil-and-nested-list-qfc4.qf1"


def form(*items):
    return list(items)


def render(expr, indent=0):
    pad = "  " * indent
    if isinstance(expr, str):
        return pad + expr
    if not expr:
        raise ValueError("empty form")

    lines = [pad + "(" + render(expr[0]).strip()]
    for item in expr[1:]:
        lines.append(render(item, indent + 1))
    lines[-1] += ")"
    return "\n".join(lines)


def seq(*stmts):
    if not stmts:
        raise ValueError("empty Seq")
    expr = stmts[-1]
    for stmt in reversed(stmts[:-1]):
        expr = form("Seq", stmt, expr)
    return expr


def defn(name, body, rest, frame="NoFrame"):
    return form("Def", name, frame, body, rest)


def data(name, byte, rest):
    return form("Data", name, byte, rest)


def string2(name, b1, b2, rest):
    return form("String2", name, b1, b2, rest)


def atom(name, chars, length, rest):
    return form("Atom", name, chars, length, rest)


def pair(name, car, cdr, rest):
    return form("Pair", name, car, cdr, rest)


def list_tail_defs():
    return pair(
        "ListA",
        form("Const", "AtomA"),
        form("Ptr", "ListB"),
        pair(
            "ListB",
            form("Const", "AtomB"),
            "Nil",
            "End",
        ),
    )


def nested_list_defs():
    return pair(
        "ListA",
        form("Const", "AtomA"),
        form("Ptr", "TailA"),
        pair(
            "TailA",
            form("Ptr", "ListB"),
            "Nil",
            pair(
                "ListB",
                form("Const", "AtomB"),
                "Nil",
                "End",
            ),
        ),
    )


def common_defs(list_defs):
    defs = atom(
        "AtomA",
        "CharA",
        "01",
        atom(
            "AtomB",
            "CharB",
            "01",
            data(
                "CharA",
                "61",
                data(
                    "CharB",
                    "62",
                    string2(
                        "NilParens",
                        "28",
                        "29",
                        data(
                            "LParen",
                            "28",
                            data(
                                "RParen",
                                "29",
                                data(
                                    "Space",
                                    "20",
                                    list_defs,
                                ),
                            ),
                        ),
                    ),
                ),
            ),
        ),
    )
    return defs


def write_source(path, header, list_defs):
    defs = common_defs(list_defs)
    print_tail = defn(
        "PrintTail",
        seq(
            form("CmpEax", "01"),
            form(
                "IfZero",
                "Done",
                form("Return"),
                seq(
                    form("PushEax"),
                    form("WriteByte", "Space"),
                    form("PopEax"),
                    form("PushEax"),
                    form("CarEax"),
                    form("CallProc", "PrintExpr"),
                    form("PopEax"),
                    form("CdrEax"),
                    form("TailCallProc", "PrintTail"),
                ),
            ),
        ),
        defs,
    )

    print_list = defn(
        "PrintList",
        seq(
            form("PushEax"),
            form("WriteByte", "LParen"),
            form("PopEax"),
            form("PushEax"),
            form("CarEax"),
            form("CallProc", "PrintExpr"),
            form("PopEax"),
            form("CdrEax"),
            form("CallProc", "PrintTail"),
            form("WriteByte", "RParen"),
        ),
        print_tail,
    )

    print_atom = defn(
        "PrintAtom",
        seq(
            form("LoadAtomCharsEcx"),
            form("LoadByteEbxFromEcx"),
            form("WriteByteFromEbx"),
        ),
        print_list,
    )

    print_nil = defn("PrintNil", form("Write2", "NilParens"), print_atom)

    print_expr = defn(
        "PrintExpr",
        seq(
            form("CmpEax", "01"),
            form(
                "IfZero",
                "NilExpr",
                form("CallProc", "PrintNil"),
                seq(
                    form("TestPairEax"),
                    form(
                        "IfZero",
                        "Pair",
                        form("CallProc", "PrintList"),
                        form("CallProc", "PrintAtom"),
                    ),
                ),
            ),
        ),
        print_nil,
    )

    start = defn(
        "Start",
        seq(
            form("LoadNilEax"),
            form("CallProc", "PrintExpr"),
            form("LoadAddrEax", "ListA"),
            form("CallProc", "PrintExpr"),
            form("Exit", form("Literal", "00")),
        ),
        print_expr,
    )

    program = form("QfcAssemble", form("Source", "Start", start))
    path.write_text(header + render(program) + "\n")


def bytes4(value):
    return " ".join(f"{byte:02X}" for byte in value.to_bytes(4, "little"))


def write_qfasm_extension(path, segment_size, max_backward, description):
    lines = [
        f"; Focused qfasm2 range extension for {description}.",
        ";",
        f"; The common qfasm2 tables stop at N220. This fixture has a {segment_size}-byte",
        f"; segment and one backward direct call at -{max_backward}, so keep the extra",
        "; finite arithmetic and byte facts local to this proof.",
        "",
    ]

    for n in range(220, segment_size):
        lines.append(f"(Inc N{n}) N{n + 1}")
    lines.append("")

    for n in range(221, segment_size + 1):
        lines.append(f"(Dec N{n}) N{n - 1}")
    lines.append("")

    base = 0x08048054
    for n in range(221, segment_size + 1):
        lines.append(f"(Addr N{n}) (Bytes {bytes4(base + n)})")
    lines.append("")

    for n in range(221, segment_size + 1):
        lines.append(f"(ConstAddr N{n}) (Bytes {bytes4(base + n + 1)})")
    lines.append("")

    lines.append(f"(FileSize N{segment_size}) (Bytes {bytes4(0x54 + segment_size)})")
    lines.append("")

    for n in range(101, max_backward + 1):
        lines.append(f"(Byte (Neg N{n})) {(256 - n) & 0xFF:02X}")
    lines.append("")

    path.write_text("\n".join(lines))


def main():
    write_qfasm_extension(
        QFASM_TAIL_EXT_OUT,
        segment_size=272,
        max_backward=189,
        description="the merged tail normal-printer fixture",
    )
    write_qfasm_extension(
        QFASM_NESTED_EXT_OUT,
        segment_size=280,
        max_backward=189,
        description="the merged nested normal-printer fixture",
    )
    write_source(
        QFC4_TAIL_SRC_OUT,
        """; qfc4 normal-printer nil-plus-tail-list fixture.
;
; This merges the focused nil branch with the tail-recursive list printer in
; one PrintExpr routine. The generated ELF prints `()(a b)`, proving nil,
; atom, pair/list dispatch, cdr traversal, separator output, and nil-tail
; termination can coexist in one compiled normal-printer slice.

""",
        list_tail_defs(),
    )
    write_source(
        QFC4_NESTED_SRC_OUT,
        """; qfc4 normal-printer nil-plus-nested-list fixture.
;
; This merges the focused nil branch with the recursive nested-list printer in
; one PrintExpr routine. The generated ELF prints `()(a (b))`, proving nil
; dispatch can coexist with nested normal output through PrintExpr recursion.

""",
        nested_list_defs(),
    )


if __name__ == "__main__":
    main()
