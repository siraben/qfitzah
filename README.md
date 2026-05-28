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
`*` through `^`, which includes digits and uppercase letters.

Repeated variables in a pattern must match the same atom:

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
pattern variables, unmatched template variables, and empty-list matching.

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
