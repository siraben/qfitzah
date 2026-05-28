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

The current build is a 32-bit static Linux executable of about 1.2 KiB. It keeps
the runtime small by using direct syscalls, a bump allocator, pointer tagging,
and ordered tree rewrite rules instead of a larger parser or object system.

## Language

Qfitzah reads one form per line.

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

## Qfitzah-Hosted Assembler Stage

[bootstrap/qfasm2.qf1](bootstrap/qfasm2.qf1) is the next bootstrap rung. It is
not an external assembler: it is a Qfitzah rule file that runs under `qfitzah`
and emits a complete i386 ELF binary.

It adds a symbolic assembly layer over direct `(Bytes ...)` emission:

- pass 1 builds a symbol table from `(Label name)` forms
- pass 2 emits instruction bytes and resolves labels
- `(Jump label)` computes a short PC-relative offset
- `(Call label)` computes a direct call displacement for the bootstrap range
- ELF `p_filesz`/`p_memsz` are selected from the assembled code size

The current implementation intentionally uses finite arithmetic tables for the
small bootstrap range; later stages should replace those tables with generated
arithmetic and richer macros.

Build the sample program:

```sh
cat bootstrap/qfasm2.qf1 bootstrap/exit42.qf1 | result/bin/qfitzah > exit42
chmod +x exit42
./exit42
echo $?
```

The expected status is `42`.

[bootstrap/qfasm3.qf1](bootstrap/qfasm3.qf1) is the next macro layer, also
hosted in Qfitzah. It expands structured macro assembly into qfasm2 data before
assembly. The current macro layer supports:

- `(Proc name clobbers body)` procedure blocks
- scoped local labels represented as `(Local proc name)`
- `(IfZero name then else)` structured conditionals
- `(Invoke name args)` call setup for register arguments
- `Ecx` clobber save/restore with `PushEcx`/`PopEcx`

The sample program is built by concatenating the stages:

```sh
cat bootstrap/qfasm2.qf1 bootstrap/qfasm3.qf1 bootstrap/stage3-exit42.qf1 \
  | result/bin/qfitzah > stage3-exit42
chmod +x stage3-exit42
./stage3-exit42
echo $?
```

[bootstrap/qfc4.qf1](bootstrap/qfc4.qf1) is the current Stage 4 compiler
slice. It is also hosted in Qfitzah. It accepts a small high-level source form,
parses it into an explicit AST, compiles that AST to qfasm3 macro assembly, then
hands the result to qfasm3/qfasm2.

The implemented source subset includes:

- function definitions with `NoFrame` or `(Preserve Ecx)` frame requests
- `(Exit expr)` statements
- `(Literal byte)`, `(Zero)`, `(Add1 expr)`, and `(ConstAtom payload)`
- declarative zero-match expressions:
  `(Match name test (Case Zero then) (Case Else otherwise))`

Build the Stage 4 match example:

```sh
cat bootstrap/qfasm2.qf1 bootstrap/qfasm3.qf1 bootstrap/qfc4.qf1 \
    bootstrap/stage4-exit42.qf1 \
  | result/bin/qfitzah > stage4-exit42
chmod +x stage4-exit42
./stage4-exit42
echo $?
```

The tagged-constant example in
[bootstrap/stage4-tagged-exit43.qf1](bootstrap/stage4-tagged-exit43.qf1)
compiles an aligned constant payload with low tag bits set and exits with
status `43`.

## Tests

```sh
nix flake check
```

The test suite covers basic rewriting, fast multi-line piped input, repeated
pattern variables, structural equality for repeated list-valued variables,
unmatched template variables, reader ergonomics, empty-list matching, nested
byte-stream flattening, the example compilers, and the Qfitzah-hosted assembler
stage. Test programs live in `tests/cases/*.qf1`, with expected snippets in
matching `.expected` files and forbidden snippets in optional `.unexpected`
files.

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

It proves the core runtime does not require languages built on top of it to be
S-expression languages; only the current bootstrap reader is S-expression-based.

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
