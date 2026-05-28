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
↪ (Id 3)
(Id 3)
```

Lines with two expressions define a rewrite rule:

```text
↪ (Id x) x
↪ (Id 3)
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
↪ (Eq x x) (Yes x)
↪ (Eq 3 3)
(Yes 3)
↪ (Eq 3 4)
(Eq 3 4)
```

Template variables that were not bound by the pattern are printed unchanged:

```text
↪ (Do Nothing) no
↪ (Do Nothing)
no
```

## Tests

```sh
nix flake check
```

The test suite covers basic rewriting, fast multi-line piped input, repeated
pattern variables, structural equality for repeated list-valued variables,
unmatched template variables, reader ergonomics, and empty-list matching. Test
programs live in `tests/cases/*.qf1`, with expected snippets in matching
`.expected` files and forbidden snippets in optional `.unexpected` files.

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
