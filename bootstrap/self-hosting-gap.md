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

That requires extending qfc4 with:

- memory loads from pair and atom objects
- conditionals over tag bits and byte comparisons
- loops or tail calls
- calls between compiled procedures
- enough data layout notation to express Qfitzah objects

Only after those pieces exist should the roadmap mark Stage 5 as implemented.
