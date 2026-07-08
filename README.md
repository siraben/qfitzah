# Qfitzah

Qfitzah is a tiny i386 Linux term-rewriting language interpreter implemented in
GNU assembly. It reads a small S-expression-like language from standard input,
stores rewrite rules, and evaluates later expressions by applying the newest
matching rule first.

The implementation is intentionally compact: it uses a static 32-bit Linux
binary with direct `int $0x80` syscalls, pointer tagging for pairs, constants,
and variables, a bump allocator, and an intern table for atom names.

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

The current build is a 32-bit static Linux executable under 2 KiB. It keeps
the runtime small by using direct syscalls, a bump allocator, pointer tagging,
and ordered tree rewrite rules instead of a larger parser or object system.

## The compiler stack

On top of the seed, this repository builds a self-hosting Scheme compiler as a
ladder of small language processors, each written in the language of the one
below it:

```text
Stage 0  qfitzah.s      seed: pattern-matching term rewriter
Stage 1  qfasm.qf1      general symbolic assembler (rewrite rules)
Stage 2  scheme0        minimal Scheme interpreter, assembled by Stage 1
Stage 3  sc1.scm        Scheme-subset compiler written in the scheme0 subset
Stage 4  rsc.scm        R5RS-subset-to-asm compiler that recompiles itself
```

Each stage stays minimal but correct, and every artifact is produced by running
the stage below it — never a host toolchain. Stages 3 and 4 close the loop by
rebuilding their own source to a byte-identical fixpoint. See
[ARCHITECTURE.md](ARCHITECTURE.md) for the full design; the sections below tour
the language and each rung.

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

Rules are tried from newest to oldest. Lowercase names and names beginning with
`_` are pattern variables. Constants are atoms beginning with characters from
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

## Bootstrap Architecture

### Stage 0: the seed

[qfitzah.s](qfitzah.s) is the trusted root: a ~1.7 KiB static i386 ELF
implementing the rewrite language. Matching supports repeated-variable
structural equality; substitution preserves unmatched template variables.
Three scaling properties matter for the stages above it, all invisible to the
language semantics:

- `evlis` reuses a pair when neither field changed after evaluation, so
  re-walking already-normal data allocates nothing.
- Rules are indexed by the head atom of their pattern (each interned atom
  carries its own rule bucket), so evaluating a term only scans plausible
  candidates. Rules whose pattern head is not a constant atom live on a
  generic list consulted after the bucket, and therefore rank below all
  head-indexed rules.
- Normal forms are memoized by pair identity. Pairs are immutable and never
  freed, so `ev(t)` is a pure function of the pointer `t` and the current rule
  set; a direct-mapped cache (invalidated by a generation counter when a rule
  is added) normalizes each subterm once. This keeps the assembler linear:
  threading a large instruction chain or symbol table through the rewrite
  passes would otherwise re-normalize those shared subterms once per step.

### Stage 1: the general assembler

[bootstrap/qfasm.qf1](bootstrap/qfasm.qf1) is a Qfitzah-hosted symbolic i386
assembler, generated by [bootstrap/gen-qfasm.scm](bootstrap/gen-qfasm.scm)
from one instruction spec so sizes and emissions cannot disagree. Numbers are
little-endian nybble lists `(N d0 ... d7)`; add/negate/subtract are built
from generated single-nybble fact tables, and byte atoms come from a
generated `(HB hi lo)` table because the seed cannot synthesize atoms at
runtime. There are no finite range tables: label arithmetic, rel8/rel32
branches, and ELF header fields work at any program size, and rel8 operands
are range-checked.

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
table compares keys structurally; that gives scoped labels for free. An
optional third `Program` field appends zero-initialized memory to the single
RWE load segment for runtime heaps.

### Stages 2-4

Stage 2 (`bootstrap/scheme0.qfasm`, a minimal Scheme interpreter written in
qfasm macro assembly and generated by
[bootstrap/gen-scheme0.scm](bootstrap/gen-scheme0.scm)) is assembled by Stage 1 into
a native ELF.

Stage 3 is `bootstrap/sc1.scm`, a Scheme-to-qfasm compiler written strictly in
the scheme0 subset, so it runs interpreted under scheme0 and compiles itself.
Its reader is `bootstrap/sc1-reader.scm`; its fixed assembly runtime (heap,
`cons`, object allocation, buffered IO, the printer, symbol interning, and
every primitive as a global closure) is `bootstrap/sc1-runtime.qf1`, generated
by [bootstrap/gen-sc1-runtime.scm](bootstrap/gen-sc1-runtime.scm) and expanded
by the seed via `(RuntimeCode ...)`/`(RuntimeData ...)` macros. sc1 compiles
closures to subtype-2 objects with a `(code . env)` payload, keeps the
environment as a heap frame-chain in EBP, and emits proper tail calls (tail
applications JMP, non-tail CALL) so tail recursion runs in constant stack.

```sh
# compile, assemble, and run a Scheme program
cat bootstrap/sc1-reader.scm bootstrap/sc1.scm prog.scm | ./scheme0.elf > prog.qfasm
cat bootstrap/qfasm.qf1 bootstrap/sc1-runtime.qf1 prog.qfasm | result/bin/qfitzah > prog.elf
chmod +x prog.elf && ./prog.elf
```

The Stage 3 milestone is self-compilation to a byte-identical fixpoint: the
native `sc1.elf` recompiles its own source (`sc1-reader.scm` + `sc1.scm`) to
output identical to the interpreted compile. This is checked by the
`sc1-fixpoint` test.

Stage 4 is `bootstrap/rsc.scm`, an R5RS-subset compiler written strictly in the
sc1 subset, so sc1 compiles it and it self-hosts to a byte-identical fixpoint.
It is sc1's codegen plus a macro-expansion pass in front and a wider runtime
(`bootstrap/rsc-runtime.qf1`, generated by
[bootstrap/gen-rsc-runtime.scm](bootstrap/gen-rsc-runtime.scm)). It shares
sc1's reader (extended with backtick/comma quasiquote sugar). What it adds over
sc1:

- Hygienic `syntax-rules` macros (`define-syntax`/`let-syntax`/`letrec-syntax`
  with literals, ellipsis `...`, and nested patterns). Every form is expanded
  to the sc1 core before codegen. Template identifiers that are not pattern
  variables, literals, or known names (keywords/primitives/globals/macros) are
  gensym-renamed per expansion, so a macro's introduced temporaries cannot
  capture a caller's local bindings.
- `quasiquote`/`unquote`/`unquote-splicing`, nested with correct depth.
- Derived special forms: `let*`, `letrec`/`letrec*`, named `let`, `cond` with
  `=>`, `when`, `unless`, `case`, `do`.
- Vectors (a new object subtype): `make-vector`, `vector`, `vector-ref`,
  `vector-set!`, `vector-length`, `vector?`, `vector->list`, `list->vector`,
  `vector-fill!`, printed as `#(...)`.
- `apply` with varargs, tail-proper (tail `apply` runs in constant stack).
- A standard-library prelude (`bootstrap/rsc-prelude.scm`) prepended to every
  compiled program: `equal?`, the `assoc`/`member` family, list ops (`append`
  `reverse` `length` `list-ref` `list-tail` `map` `for-each`), integer helpers
  (`abs` `modulo` `min` `max` `gcd` `even?`/`odd?`/`zero?` ... `number->string`),
  the char predicate/compare/case library, and the string library (`string`
  `substring` `string-append` `string=?` `string<?` `string->list`
  `make-string`/`string-set!` `string-copy`).

rsc.scm itself uses none of these surface features (it is plain sc1-subset
source), so its self-host fixpoint only re-exercises sc1's proven codegen; the
new features are covered by a separate corpus. Out of scope (documented in
[ARCHITECTURE.md](ARCHITECTURE.md)): bignums/numeric tower beyond 30-bit exact
integers, floats/rationals, full `call/cc`/`dynamic-wind`, first-class `eval`,
`delay`/`force`, and `#(...)` vector read syntax (vectors are built by the
constructors above).

```sh
# compile, assemble, and run an R5RS program with rsc
cat bootstrap/sc1-reader.scm bootstrap/rsc.scm | ./sc1.elf > /dev/null   # rsc built by sc1
cat bootstrap/rsc-prelude.scm prog.scm | ./rsc.elf > prog.qfasm
cat bootstrap/qfasm.qf1 bootstrap/rsc-runtime.qf1 prog.qfasm | result/bin/qfitzah > prog.elf
chmod +x prog.elf && ./prog.elf
```

The Stage 4 milestone is the self-host fixpoint: sc1 compiles `rsc.scm` to
`rscA.elf`; `rscA` compiles `rsc.scm` to `rscB`; `rscB` compiles `rsc.scm` to
`rscC`; `rscB` and `rscC` are byte-identical. This is checked by the
`rsc-fixpoint` test, alongside an R5RS corpus (macros, quasiquote, derived
forms, the library, vectors, apply) compiled by rsc, assembled, run, and
diffed.

## Tests

```sh
nix flake check
```

The test suite covers basic rewriting, fast multi-line piped input, final
multi-line records at EOF, the multi-line rule directive, repeated pattern
variables, structural equality for repeated list-valued variables, unmatched
template variables, reader ergonomics, empty-list matching, nested byte-stream
flattening, the example compilers, and the Stage 1 assembler: random 32-bit
arithmetic and two whole programs (including an 8 KiB, 2868-instruction one)
checked byte-for-byte against an independent byte model, then executed. Test
programs live in `tests/cases/`, with expected snippets in matching `.expected`
files and forbidden snippets in optional `.unexpected` files; assembler fixtures
are regenerated by
[bootstrap/gen-qfasm-tests.scm](bootstrap/gen-qfasm-tests.scm).

The suite also assembles and runs Stage 2 (the scheme0 interpreter over a
Scheme corpus and the sc1 reader) and Stage 3: it compiles `sc1-corpus.scm`
(arithmetic/recursion, higher-order `map`, closures via `set!`, quoted data
with `string->symbol`, strings/chars, predicates) and `sc1-tail.scm` (a
million-iteration tail loop) with interpreted sc1, then checks the
self-compilation fixpoint — the native `sc1.elf` recompiling sc1's own source
byte-for-byte.

Stage 4 adds the `rsc-fixpoint` test (sc1 builds `rsc.elf`; rsc recompiles its
own source to a byte-identical fixpoint) and an R5RS corpus — `rsc-macros`
(hygiene, ellipsis, recursion, `let-syntax`), `rsc-derived` (`let*`/`letrec`/
named `let`/`when`/`unless`/`case`/`do`/`cond =>` and quasiquote), `rsc-library`
(the standard-library prelude), `rsc-vectors`, and `rsc-apply` — each compiled
by rsc, assembled, run, and diffed.

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
