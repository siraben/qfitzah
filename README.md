# Qfitzah

Qfitzah is a tiny i386 Linux term-rewriting language interpreter implemented in
GNU assembly. It reads a small S-expression-like language from standard input,
stores rewrite rules, and evaluates later expressions by applying matching
rules. Head-indexed rules take priority over generic rules; within each group,
the newest matching rule wins.

The interpreter uses direct `int $0x80` syscalls, pointer-tagged values,
a small nonmoving collector, and an intern table for atom names.

## Active bootstrap target

Development now targets [blynn-bootstrap](https://github.com/siraben/blynn-bootstrap)
and its Blynn/HCC → TinyCC path, rooted in qfitzah rather than additional binary
seeds. A fresh complete build passed in **24m11s**, including compiler/runtime
self-rebuilds, execution tests and independent byte-for-byte reproduction.
See [the acceptance report](bootstrap/blynn/ACCEPTANCE.md),
[build instructions and limitations](bootstrap/blynn/README.md), and
[the dependency audit](bootstrap/blynn/DEPENDENCIES.md).

## Build

Build the executable with Nix:

```sh
nix build
```

Run it from the build result:

```sh
result/bin/qfitzah
```

Or run it directly:

```sh
nix run
```

The flake builds `qfitzah.s` with GNU `as`, links a static i386 executable with
`ld`, and strips nonessential metadata with `objcopy`.

The executable is 2,544 bytes (~2.5 KiB), including the collector.

## The compiler stack

The bootstrap builds a Scheme interpreter and two self-compiling compilers:

```text
Stage 0  qfitzah.s      seed: pattern-matching term rewriter
Stage 1  qfasm.qf1      general symbolic assembler (rewrite rules)
Stage 2  scheme0        minimal Scheme interpreter, assembled by Stage 1
Stage 3  sc1.scm        Scheme-subset compiler written in the scheme0 subset
Stage 4  rsc.scm        R5RS-subset-to-asm compiler that recompiles itself
```

GNU binutils builds the seed. Qfitzah expands the source macros and assembles
each later stage. See [ARCHITECTURE.md](ARCHITECTURE.md) for the implementation
and known limitations.

## Language

Qfitzah reads one logical record at a time.

Lines with one expression evaluate that expression:

```text
(Id 3)
(Id 3)
```

Lines with two expressions define a rewrite rule:

```text
(Id x) x
(Id 3)
3
```

Parenthesized forms may span physical lines. A rewrite record is processed once
its parenthesis depth returns to zero:

```text
(Pair
  x
  y) (Cons x y)

(Pair
  A
  B)
```

For a rule whose pattern and replacement should each be on their own lines, use
the explicit rule directive:

```text
(Rule
  (Pair
    x
    y)
  (Cons
    x
    y))
```

This directive lets the pattern and replacement each span several lines, which
a bare two-form rule cannot.

Dotted tails expose the underlying pairs, including list-tail patterns:

```text
(Head (x . xs)) x
(Tail (x . xs)) xs
(Prepend x xs) (x . xs)
(Tail (A B . C))
(B . C)
(Prepend A (B C))
(A B C)
```

A standalone `.` is reserved for a list tail; `A.B`, `.Name`, and `...` remain
atoms. `(A . (B C))` and `(A B C)` are the same value, not different evaluation
forms. To compute a tail, pass the computation as an ordinary argument, then
splice its result with `(x . xs)`. Improper lists print with a dot, so reading
and printing preserve their structure.

Malformed dotted tails, incomplete records, extra record/directive arguments,
input NUL bytes, and improper byte streams exit with status 1 and a stderr
diagnostic. Comments work inside multiline forms and between records.

Rules are tried newest-first within the head-atom bucket, then newest-first
within the generic bucket. Thus a newer generic rule does not override an older
head-specific rule. Lowercase names and names beginning with `_` are pattern variables. Constants are atoms beginning with characters from
`!` through `'` or `*` through `^`, which includes digits, uppercase letters,
and punctuation such as `#`, `$`, `%`, `+`, `-`, and `=`.

Spaces, tabs, and carriage returns are whitespace. Semicolons start comments
that run to the end of the line:

```text
; identity rule
(Id x) x
(Id Bang!) ; => Bang!
```

Repeated variables in a pattern must match the same term:

```text
(Eq x x) (Yes x)
(Eq 3 3)
(Yes 3)
(Eq 3 4)
(Eq 3 4)
```

Template variables that were not bound by the pattern are printed unchanged:

```text
(Do Nothing) no
(Do Nothing)
no
```

If an evaluated expression returns `(Bytes XX YY ...)`, Qfitzah writes those
two-hex-digit byte atoms directly to stdout with no trailing newline. This makes
the runtime usable as a tiny macro assembler seed:

```text
(AsmExit code) (Bytes B8 01 00 00 00 BB code 00 00 00 CD 80)
(AsmExit 2A)
```

```sh
nix run < examples/byte-assembler.qf1 > exit42.bin
```

The example emits this i386 Linux machine-code fragment:

```text
b8 01 00 00 00 bb 2a 00 00 00 cd 80
```

Byte output also accepts `(Hex high low)` inside `(Bytes ...)`, including nested
byte streams. Each digit is an uppercase hex atom and may be computed by rules:

```text
(ByteFromDigits hi lo) (Bytes (Hex hi lo))
(ByteFromDigits 2 A)
```

This emits `2a`. Invalid or unresolved byte terms exit with status 1 and a
stderr diagnostic before flushing the record. Discard stdout on failure;
earlier records may already have been written.

## Bootstrap Architecture

### Stage 0: the seed

[qfitzah.s](qfitzah.s) implements the rewrite language. Matching checks
structural equality for repeated variables; substitution leaves unmatched
template variables unchanged. Evaluation uses three optimizations:

- `evlis` reuses a pair when neither field changed after evaluation, so
  re-walking already-normal data allocates nothing.
- Rules are indexed by the head atom of their pattern (each interned atom
  carries its own rule bucket), so evaluating a term only scans plausible
  candidates. Rules whose pattern head is not a constant atom live on a
  generic list consulted after the bucket, and therefore rank below all
  head-indexed rules.
- Normal forms are memoized by pair identity. Live pairs are immutable, so
  `ev(t)` depends only on `t` and the current rule set. A direct-mapped weak
  cache (invalidated when a rule is added or garbage is collected) avoids
  repeated normalization on cache hits. This mitigates repeated
  traversal of shared instruction chains and symbol tables. Cache collisions
  cause recomputation.

### Stage 1: the general assembler

[bootstrap/qfasm.qf1](bootstrap/qfasm.qf1) is a symbolic i386 assembler.
Each `Describe` rule specifies encoding fields: `B` is one byte, `W` a four-byte
word and `R` a checked relative byte. The layout and emission passes share
prepared descriptors containing the fields and their total width.

Numbers are little-endian nybble lists `(N d0 ... d7)`. An eight-case bit full
adder implements nybble addition; bit packing computes ModRM/opcode fields from
eight register declarations. Zero-add identities avoid expanding unused high
digits. `(HB hi lo)` produces `(Hex hi lo)`. Address arithmetic is 32-bit;
buffers, heap and stack have fixed limits. rel8 operands and single-byte field
widths are checked, and unresolved assembly is rejected by the seed.

Programs are data:

```text
(Assemble (Program Start
  (Ins (Label Start)
  (Ins (MovRI EAX (X8 0 0 0 0 0 0 0 1))
  (Ins (MovRI EBX (X8 0 0 0 0 0 0 2 A))
  (Ins (Int 80)
  End))))))
```

```sh
cat bootstrap/qfasm.qf1 tests/cases/qfasm-exit42.qfasm | result/bin/qfitzah > exit42
chmod +x exit42 && ./exit42; echo $?   # 42
```

Label names may be arbitrary terms, e.g. `(Local Reader 1)`, since the symbol
table compares keys structurally. The form `(Program entry bss code)` adds
`bss` bytes of zero-initialized memory to the single RWE load segment.

### Stages 2-4

Stage 2 (`bootstrap/scheme0.qfasm`) is a Scheme interpreter written in flat
assembly. [bootstrap/runtime-support.qf1](bootstrap/runtime-support.qf1)
expands primitive declarations, name bytes and instruction blocks. See
[ARCHITECTURE.md](ARCHITECTURE.md#shared-assembly-macros-bootstrapruntime-supportqf1)
for the macro syntax.

Stage 3 is `bootstrap/sc1.scm`, a Scheme-to-qfasm compiler written strictly in
the scheme0 subset, so it runs interpreted under scheme0 and compiles itself.
Its reader is `bootstrap/sc1-reader.scm`; its fixed assembly runtime (heap,
`cons`, object allocation, buffered IO, the printer, symbol interning, and
every primitive as a global closure) is `bootstrap/sc1-runtime.qf1`,
expanded with `runtime-support.qf1` via
`(RuntimeCode ...)`/`(RuntimeData ...)` macros. sc1 compiles
closures to subtype-2 objects with a `(code . env)` payload, keeps the
environment as a heap frame-chain in EBP, and emits JMP for direct tail
applications and CALL for non-tail applications. Tail position through `and`/`or`
is lost; see `tests/probe-semantics.sh`.

```sh
# compile, assemble, and run a Scheme program
cat bootstrap/sc1-reader.scm bootstrap/sc1.scm prog.scm | ./scheme0.elf > prog.qfasm
cat bootstrap/qfasm.qf1 bootstrap/runtime-support.qf1 bootstrap/sc1-runtime.qf1 prog.qfasm | result/bin/qfitzah > prog.elf
chmod +x prog.elf && ./prog.elf
```

The native `sc1.elf` recompiles its source (`sc1-reader.scm` + `sc1.scm`) to
assembly text identical to the interpreted compile. `sc1-fixpoint` also assembles
that text and compares the complete ELFs, then the rebuilt compiler compiles and
runs the corpus and tail-call test.

Stage 4 is `bootstrap/rsc.scm`, an R5RS-subset compiler written strictly in the
sc1 subset, so sc1 compiles it and it self-hosts to a byte-identical fixpoint.
It is sc1's codegen plus a macro-expansion pass in front and a wider runtime
(`bootstrap/rsc-runtime.qf1`, using `runtime-support.qf1` and `gc.qf1`). It shares sc1's
reader, with backtick/comma quasiquote syntax. What it adds over
sc1:

- Gensym-based `syntax-rules` macros (`define-syntax`/`let-syntax`/`letrec-syntax`
  with literals, ellipsis `...`, and nested patterns). Every form is expanded
  to the sc1 core before codegen. Template identifiers that are not pattern
  variables, literals, or known names (keywords/primitives/globals/macros) are
  gensym-renamed per expansion. This prevents some temporary capture but does
  not implement full lexical hygiene; definition-site free identifiers and
  binding-sensitive literal matching remain limitations.
- `quasiquote`/`unquote`/`unquote-splicing` (nested splicing still needs correction).
- Derived special forms: `let*`, `letrec`/`letrec*`, named `let`, `cond` with
  `=>`, `when`, `unless`, `case`, `do`.
- Vectors: `make-vector`, `vector`, `vector-ref`,
  `vector-set!`, `vector-length`, `vector?`, `vector->list`, `list->vector`,
  `vector-fill!`, printed as `#(...)`.
- `apply` with varargs, tail-proper and without mutating caller argument lists.
- Lexical internal definitions, full-range fixnum literals, and tail `and`/`or`.
- Nonmoving conservative GC for cells and string/vector storage; bounded
  allocation failure and explicit `gc`/`gc-count` testing primitives. See
  [the collector invariants](ARCHITECTURE.md#rsc-memory-management-bootstrapgcqf1).
- A standard-library prelude (`bootstrap/rsc-prelude.scm`) that the caller
  prepends when needed: `equal?`, the `assoc`/`member` family, list ops (`append`
  `reverse` `length` `list-ref` `list-tail` `map` `for-each`), integer helpers
  (`abs` `modulo` `min` `max` `gcd` `even?`/`odd?`/`zero?` ... `number->string`),
  the char predicate/compare/case library, and the string library (`string`
  `substring` `string-append` `string=?` `string<?` `string->list`
  `make-string`/`string-set!` `string-copy`).

rsc.scm is written in the sc1 subset. Its self-compilation tests the inherited
code generator; a separate corpus tests the added features. The core compiler still lacks floats, rationals, first-class `eval`,
`delay`/`force`, and `#(...)` source vector syntax. The separately compiled
runtime libraries add exact integers, port-aware reading, and dynamic control
without expanding the sc1 bootstrap subset; see below.

```sh
# compile, assemble, and run an R5RS program with rsc
cat bootstrap/sc1-reader.scm bootstrap/rsc.scm | ./sc1.elf > rsc.qfasm
bash bootstrap/assemble.sh result/bin/qfitzah rsc rsc.qfasm > rsc.elf
chmod +x rsc.elf
cat bootstrap/rsc-prelude.scm prog.scm | ./rsc.elf > prog.qfasm
bash bootstrap/assemble.sh result/bin/qfitzah rsc prog.qfasm > prog.elf
chmod +x prog.elf && ./prog.elf
```

sc1 compiles `rsc.scm` to `rscA.elf`; `rscA` compiles `rsc.scm` to `rscB`;
`rscB` compiles `rsc.scm` to
`rscC`; the B/C assembly texts and complete assembled ELFs must be byte-identical.
This is checked by `rsc-fixpoint`. The R5RS-subset corpus (macros, quasiquote,
derived forms, library, vectors, apply) is compiled through both sc1-built A and
self-built C, assembled, executed, and diffed. The standard-library prelude is
supplied by the caller, as shown above, not automatically loaded by the compiler.

### Source-built runtime libraries

Additional Scheme libraries, compiled by rsc in this order:

1. `rsc-prelude.scm`: base list/string/integer helpers.
2. `rsc-control.scm`: multi-shot `call/cc`, `dynamic-wind`, multiple values,
   exceptions and fluid bindings, over the native stack-snapshot primitive.
3. `rsc-ports.scm`: buffered input, checked file operations, string ports,
   current ports and escaped printing.
4. `rsc-integers.scm`: arbitrary-size exact integers and bit operations.
5. `rsc-reader.scm`: port-aware data reader, vectors, keywords, radix numbers,
   nested comments and escapes. This does not change the core compiler reader.

`bootstrap/assemble.sh` supplies the required assembly modules in order.
These libraries are source, not precompiled host dependencies.

## Tests

```sh
nix flake check
```

The suite tests rewriting, reader syntax, byte output, assembler encodings and
layout, source macros, the Scheme corpora and compiler fixpoints. It compares
complete ELF files and runs programs compiled by the rebuilt compilers. Nix
checks receive only the seed and bootstrap, example and test sources.

Test programs live in `tests/cases/`. `.expected` files contain exact transcripts;
`.hex` files contain expected bytes. The arithmetic and ELF fixtures were
generated by `3777b7d:tools/generate_qfasm_tests.py`. The large ELF fixture's
randomized body is byte-compared but jumped over during execution.

- `tests/boundaries.sh`: all byte values, nybble sums and supported register
  encodings; malformed source and assembly.
- `tests/instruction-encodings.sh`: bytes and widths for every descriptor.
- `tests/assembler-layout.sh`: alignment, ELF fields and branch boundaries.
- `tests/source-macros.sh`: blocks, nested splices and declaration expansion.

`bash tests/probe-semantics.sh result/bin/qfitzah` runs separate tests for known
Scheme bugs and exits nonzero on failures. See
[known bugs](ARCHITECTURE.md#limits-and-known-bugs) for details.

You can also run it against a built binary:

```sh
tests/run.sh ./result/bin/qfitzah
```

## Example Compiler

[examples/arithmetic-compiler.qf1](examples/arithmetic-compiler.qf1)
is a small compiler from arithmetic expression trees to a stack-machine program.

Source expressions use this shape:

```text
(Num 2)
(Add (Num 2) (Num 3))
(Mul (Add (Num 2) (Num 3)) (Num 4))
```

The target stack program is continuation-shaped:

```text
Done
(Push 2 Done)
(Push 2 (Push 3 (Add Done)))
```

The compiler rules are:

```text
(Compiler expr) (Compile expr Done)
(Compile (Num n) k) (Push n k)
(Compile (Add left right) k) (Compile left (Compile right (Add k)))
(Compile (Sub left right) k) (Compile left (Compile right (Sub k)))
(Compile (Mul left right) k) (Compile left (Compile right (Mul k)))
```

Run the example:

```sh
nix run < examples/arithmetic-compiler.qf1
```

It compiles:

```text
(Add (Num 2) (Mul (Num 3) (Num 4)))
```

to:

```text
(Push 2 (Push 3 (Push 4 (Mul (Add Done)))))
```

## Example Meta-II Style Parser

[examples/meta2-arithmetic.qf1](examples/meta2-arithmetic.qf1) shows how
to build a more Meta-II-like language layer without changing the tiny Qfitzah
reader. The example parses token streams, builds arithmetic ASTs with precedence,
then feeds those ASTs into the stack compiler.

The object language token stream:

```text
2 Plus 3 Star 4
```

is represented as data:

```text
(Tok (N 2) (Tok Plus (Tok (N 3) (Tok Star (Tok (N 4) End)))))
```

and parsed by rules shaped like a grammar:

```text
(ParseExpr tokens) (ParseExprTail (ParseTerm tokens))
(ParseTerm tokens) (ParseTermTail (ParseFactor tokens))
(ParseFactor (Tok (N n) rest)) (Ok (Num n) rest)
```

Run it:

```sh
nix run < examples/meta2-arithmetic.qf1
```

It shows the core runtime does not require languages built on top of it to be
S-expression languages; only the seed's own reader is S-expression-based.

## Example Compiler And VM

[examples/self-hosting-compiler.qf1](examples/self-hosting-compiler.qf1)
is a compile-and-run pipeline for a small Lisp-like AST language. It compiles
source forms to stack bytecode, then runs that bytecode in a VM written in
Qfitzah.

The source language includes:

- `(Quote value)`
- `(Var name)`
- `(If condition then else)`
- `(Call Cons left right)`
- `(Call Car value)`
- `(Call Cdr value)`
- `(Call Nullp value)`
- one- and two-argument global function calls

The compiler emits bytecode such as:

```text
(Push value k)
(Load name k)
(ConsI k)
(Branch then else)
(Call1 name k)
(Call2 name k)
```

The VM executes bytecode with an explicit stack, environment, compiled
definition table, and return continuation. The example compiles recursive
`Reverse`/`RevAppend` definitions, then executes the compiled program to produce:

```text
(Cons E (Cons D (Cons C (Cons B (Cons A Nil)))))
```

## Example Lisp

[examples/lisp.qf1](examples/lisp.qf1) bootstraps a small Lisp-like
evaluator inside Qfitzah. It supports:

- `(Quote value)`
- `(Var name)` with explicit environments
- `(Lambda name body)` lexical closures
- `(App function argument)` for first-class unary functions
- `(LambdaN params body)` and `(AppN function args)` for variadic application
- `(Let name value body)`
- `(If condition then else)`
- one-, two-, and variadic `(Call ...)` forms
- global `Fn1`, `Fn2`, and `FnN` definitions
- explicit rest parameters as `(Rest name)` without dotted-list syntax
- primitive `Cons`, `Car`, `Cdr`, `List`, `Nullp`, `Atomp`, and atom `Eqp`

The example checks quoting, list primitives, conditionals, atom equality,
closures, lexical capture, lexical shadowing, higher-order function return, and
variadic/rest-parameter calls, plus a recursive `Reverse` function written in
the object Lisp using a tail-recursive helper `RevAppend`.

Run the full example:

```sh
nix run < examples/lisp.qf1
```

The reverse test evaluates this list:

```text
(Cons A (Cons B (Cons C (Cons D (Cons E Nil)))))
```

and returns:

```text
(Cons E (Cons D (Cons C (Cons B (Cons A Nil)))))
```

[examples/lisp-reverse.qf1](examples/lisp-reverse.qf1) is a smaller
single-purpose version that only defines enough of the object Lisp to reverse
the list.

Some sample object Lisp forms:

```text
(Lisp NoDefs (App (Lambda X (Var X)) (Quote IdentityWorks)))
(Lisp NoDefs (Let X (Quote Captured) (App (Lambda Y (Var X)) (Quote Ignored))))
(Lisp NoDefs (App (App (Lambda X (Lambda Y (Var X))) (Quote First)) (Quote Second)))
(Lisp NoDefs (AppN (LambdaN (Cons Head (Rest Tail)) (Call Cons (Var Head) (Var Tail))) (Cons (Quote A) (Cons (Quote B) (Cons (Quote C) Nil)))))
```
