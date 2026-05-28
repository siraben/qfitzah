# Self-Hosting Gap

The current bootstrap chain is not self-hosting in the strong sense.

It can do this:

```text
qfitzah seed runtime
  -> qfasm2.qf1 symbolic assembler
  -> qfasm3.qf1 macro assembler
  -> qfc4.qf1 small compiler slice
  -> runnable i386 ELF examples
```

It cannot yet reimplement the full `qfitzah.s` interpreter in one of the staged
languages.

## What A Real Self-Host Must Cover

A staged reimplementation of `qfitzah.s` needs source-level support for these
runtime mechanisms:

- input buffering and line-oriented reading
- S-expression reader with atoms, variables, lists, empty lists, comments, and
  malformed-input behavior
- atom interning and the atom table representation
- pair allocation and pointer tagging
- structural pattern matching with repeated-variable equality
- substitution with unbound template variables preserved
- evaluator rule ordering and recursive evaluation
- byte output, including nested `(Bytes ...)` flattening
- printing of normal S-expression results
- direct Linux syscall output and process exit

The current qfc4 compiler slice only covers a tiny source subset:

- function definitions
- exit statements
- literals, zero, add-one, tagged constants
- a zero-match conditional
- byte loads, byte stores through `write(2)`, small register arithmetic, and
  frame-preservation requests for the bootstrap byte-output path

That is enough to prove the staged assembler/compiler pipeline, but not enough
to compile the interpreter.

## Next Concrete Milestone

The next milestone should be a `qfitzah-runtime.qfc4` or successor source file
that incrementally reimplements one real runtime subsystem at a time. A useful
first target is the byte-output path because it is small but real:

```text
is_bytes + emit_bytes + emit_byte + nybble
```

Progress so far:

- `stage4-nybble.qf1` compiles the `nybble` routine shape through qfc4,
  qfasm3, and qfasm2 into a runnable ELF.
- The compiled program loads byte `A` from static data, calls `Nybble`,
  performs the subtract/compare/conditional-subtract sequence, and exits with
  status `10`.
- `stage4-emit-byte.qf1` compiles the next routine shape: load two ASCII hex
  digits, call `Nybble` twice, combine high/low nybbles, and write one byte to
  stdout. The generated ELF writes byte `41` (`A`) and exits with status `0`.
- `stage4-emit-bytes.qf1` compiles a recursive `EmitBytes`-shaped byte-span
  walker. It loads bytes through `ECX`, preserves `ECX` and `EDX` around
  `write(2)`, decrements a count in `EDX`, and performs a backward recursive
  call until the count reaches zero. The generated ELF writes `ABCDE`.
- `stage4-emit-bytes-object.qf1` compiles a static tagged `(Bytes 41)` object
  and emits it through a closer byte-output path: check the `Bytes` head atom,
  take the cdr, recursively walk the cons-list tail, load the atom character
  pointer, decode the hex atom, and write byte `41`.
- `stage4-emit-bytes-nested.qf1` compiles a focused nested fixture,
  `(Bytes (Bytes 41))`. It checks a list element with `IsBytes`, recognizes the
  nested `Bytes` object, takes its cdr, recursively emits the nested tail, and
  writes byte `41`.
- `stage4-emit-bytes-general.qf1` combines cons-tail traversal and nested
  `Bytes` flattening in one compiled `EmitBytes` routine. It uses
  `TailCallProc` for the recursive outer-list loop and emits static
  `(Bytes (Bytes 41))` as byte `41`.

Still required for the byte-output path:

- allocation or loading of non-static pair and atom objects
- larger object graphs beyond the current finite layout budget
- full `is_bytes` behavior over arbitrary interned atoms, not just the shared
  static `Bytes` atom used by the compiled object fixtures
- enough data layout notation to express larger Qfitzah object graphs
- integration with evaluated expression output and the normal printer

Only after those pieces exist should the roadmap mark Stage 5 as implemented.

## Reader Progress

The seed reader now supports parenthesized forms spanning physical lines. The
input loop accumulates bytes until parenthesis depth returns to zero, ignores
parentheses inside semicolon comments, terminates the logical record with NUL,
and lets the parser treat embedded newlines as whitespace.

This improves the bootstrap substrate for readable staged sources, but it is
not yet a fully general stream reader. A traditional two-form rewrite rule is
still a single logical record containing the pattern and replacement, but
readable multi-line rules can now be written as `(Rule pattern replacement)`.
`bootstrap/qfasm3.qf1`, `bootstrap/qfc4.qf1`, and their sample inputs now use
that style, so the macro-assembler and compiler stages depend on the improved
reader rather than merely testing it in isolation.
