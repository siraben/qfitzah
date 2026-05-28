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
- one frame-preservation request

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

Still required for the byte-output path:

- memory loads from pair and atom objects, not just static bytes
- conditionals over tag bits and byte comparisons
- loops or tail calls over `(Bytes ...)` lists
- enough data layout notation to express Qfitzah objects
- compiled `is_bytes` and recursive `emit_bytes`

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
