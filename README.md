# Qfitzah

A 1680-byte hand-written i386 term-rewriting seed grows, through a ladder of
small language processors, into a full GNU Mes that reaches the MesCC
self-recompilation fixpoint and compiles a byte-identical, self-hosting TinyCC —
with no C and no Python anywhere in the build path.

```text
seed (1680 B asm) → qfasm → scheme0 → sc1 → rsc → asm.elf → qmes (GNU Mes) → MesCC → TinyCC
```

Every artifact is produced by the stage below it. The only trusted binary is the
1680-byte committed seed, byte-reproducible from `qfitzah.s`. The seed is a tiny
i386 Linux term-rewriting interpreter written in GNU assembly: it reads a small
S-expression language from stdin, stores rewrite rules, and evaluates
expressions by applying the newest matching rule first — with pointer tagging,
a bump allocator, an interned atom table, head-atom rule indexing, and
normal-form memoization keeping it fast enough to host everything above it.

- **The ladder** — each rung is a real language processor written in the
  language of the one below it, only as large as it needs to be: a symbolic
  assembler in rewrite rules, a minimal Scheme interpreter, a Scheme-subset
  compiler, an R5RS-subset compiler, a native assembler (that escapes the seed's
  memory ceiling), and a transliteration of GNU Mes's C core. See
  [ARCHITECTURE.md](ARCHITECTURE.md).
- **The endgame** — qmes runs GNU Mes's MesCC unmodified to a byte-identical
  `src/*.c` self-recompilation fixpoint, then compiles TinyCC to a
  byte-identical, self-hosting binary. See [docs/mes-bootstrap.md](docs/mes-bootstrap.md)
  and [docs/qmes.md](docs/qmes.md).

## Results

| gate | result |
|---|---|
| Stage 3 sc1 self-host | recompiles its own source to a byte-identical fixpoint |
| Stage 4 rsc self-host | recompiles its own source to a byte-identical fixpoint |
| asm.elf | byte-identical to `[seed + qfasm.qf1]` on all shared inputs; self-fixpoint |
| MesCC i386 F1 | 20/20 units byte-identical to `bin/mes-m2` |
| MesCC i386 F2 | linked `mes` binary byte-identical from each path |
| MesCC i386 F3 | self-recompilation 20/20 on the qmes-lineage binary |
| MesCC x86_64 F1-64 | 20/20 units byte-identical to `bin/mes-m2-64` |
| MesCC x86_64 F2-64 | linked amd64 binary byte-identical |
| MesCC x86_64 F3-64 | **not closed** — a GNU Mes 0.27.1 amd64 limitation, not a qfitzah one; the reference-path binary is byte-identical and crashes identically (see [docs/mes-bootstrap.md](docs/mes-bootstrap.md)) |
| TinyCC T1 | qmes compiles the 10 tcc units 10/10 byte-identical to the reference |
| TinyCC T2 | linked `tcc` binary byte-identical to the reference |
| TinyCC T3 | qmes-built tcc self-hosts: `boot5 == boot6` |

## Quick start

Clone with submodules (the Mes/nyacc/tinycc sources are `third_party/`
submodules):

```sh
git clone --recursive <url>
# or, in an existing clone:
git submodule update --init
```

Run the suite — this needs only `sh`, `coreutils`, and an i386-capable Linux
kernel. It uses the committed seed (`bootstrap/seed/qfitzah`) and no toolchain
at all:

```sh
make check
```

Build the Mes interpreter and diff it against the reference boot chain:

```sh
make qmes           # seed -> qfasm -> scheme0 -> sc1 -> rsc -> asm.elf -> qmes.elf
make boot-ladder    # run qmes over the Mes boot chain vs the committed reference
```

Nix is optional. `nix build` builds only the seed (the ladder is Make's job);
the reference/fixpoint scripts self-enter a Nix shell for mescc-tools when
needed. `make check` is the canonical entry point.

### The verification ladder

The build has no trusted binary but the seed. These run offline from a fresh
clone, needing only the committed seed and (for the sweep gates) qmes:

```sh
make verify-seed    # rebuild the seed from qfitzah.s and byte-compare it
make regen-verify   # prove every generated artifact is reproduced by its bootstrap/gen-*.scm
make fixpoint-verify  # qmes MesCC sweep vs committed hashes (no M2-Planet needed)
make tcc-verify       # qmes tcc sweep vs committed hashes
```

The full, reference-rebuilding gates run the complete cross-host comparison and
need the M2-Planet reference plus mescc-tools (Nix-gated):

```sh
make mes-reference  # (re)build bin/mes-m2 the M2-Planet way, hash-pinned
make fixpoint       # F1/F2/F3: qmes MesCC vs bin/mes-m2, link, self-host (i386)
make fixpoint-64    # F1-64/F2-64/F3-64 via qmes64 vs bin/mes-m2-64 (x86_64)
make tcc-reference  # T0: build the reference TinyCC under bin/mes-m2
make tcc            # T1/T2/T3: qmes compiles TinyCC byte-identically, self-hosts
```

## Trust and verification

The strongest property of this project is that every artifact is produced by the
stage below it, and the only binary you must trust is the 1680-byte seed —
hand-auditable and byte-reproducible from `qfitzah.s`. C and Python appear
nowhere; Nix is needed only to rebuild the comparison baselines; offline
hash-pinned gates exist for everything expensive.

| artifact | produced by | verified by |
|---|---|---|
| `bootstrap/seed/qfitzah` (the seed) | `qfitzah.s` via `as`/`ld`/`objcopy` | `make verify-seed` (byte-identical rebuild) |
| `qfasm.qf1`, runtimes, test fixtures | `bootstrap/gen-*.scm` (in-dialect) | `make regen-verify` (byte-identical) |
| sc1, rsc compilers | the stage below (seed → … → sc1) | self-host fixpoints in `make check` |
| `asm.elf` | rsc + seed (one-time bootstrap) | differential vs seed + self-fixpoint |
| qmes | seed → … → rsc → asm.elf | boot ladder + GC stress + MesCC hello gate |
| MesCC `.s` output | qmes running Mes's MesCC | `make fixpoint-verify` vs committed hashes |
| TinyCC | qmes MesCC + mescc-tools | `make tcc-verify`; T2/T3 in `make tcc` |
| `bin/mes-m2`, `bin/mes-m2-64` | M2-Planet (comparison baseline only) | `make mes-reference`; hash-pinned, never an input |

The tracked reference binaries `bin/mes-m2*` are the *comparison baseline*, not
an input to any qfitzah artifact. They are reproducible (`make mes-reference`)
and hash-pinned, so a fresh clone can verify offline; trusting them is not
required for the bootstrap claim.

## Credits

The qfitzah seed language and its i386 interpreter (`qfitzah.s`) are the work of
**Kragen Javier Sitaker**. This project builds the bootstrapping ladder on top
of that seed. GNU Mes, MesCC, nyacc, and TinyCC (janneke's `mes-0.27` branch)
are vendored as `third_party/` submodules; the top of the ladder is a
transliteration of GNU Mes's C core into the ladder's own dialect.

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

For a rule whose pattern and replacement should each span several lines, use the
explicit `(Rule pattern replacement)` directive, which a bare two-form rule
cannot express.

Rules are tried from newest to oldest. Lowercase names and names beginning with
`_` are pattern variables. Constants are atoms beginning with characters from
`!` through `'` or `*` through `^`, which includes digits, uppercase letters,
and punctuation such as `#`, `$`, `%`, `+`, `-`, and `=`. Spaces, tabs, and
carriage returns are whitespace; semicolons start line comments. Repeated
variables in a pattern must match the same term, and template variables that
were not bound by the pattern are printed unchanged.

If an evaluated expression returns `(Bytes XX YY ...)`, Qfitzah writes those
two-hex-digit byte atoms directly to stdout with no trailing newline. This makes
the runtime usable as a tiny macro assembler seed:

```text
(AsmExit code) (Bytes B8 01 00 00 00 BB code 00 00 00 CD 80)
(AsmExit 2A)
```

```sh
bootstrap/seed/qfitzah < examples/byte-assembler.qf1 > exit42.bin
```

emits the i386 Linux machine-code fragment
`b8 01 00 00 00 bb 2a 00 00 00 cd 80`.

## Example: the byte assembler

On top of the seed, [bootstrap/qfasm.qf1](bootstrap/qfasm.qf1) is a Qfitzah-hosted
symbolic i386 assembler expressed entirely in rewrite rules. Programs are data:

```text
(Assemble (Program Start
  (Ins (Label Start)
  (Ins (MovRI EAX (X8 0 0 0 0 0 0 0 1))
  (Ins (MovRI EBX (X8 0 0 0 0 0 0 2 A))
  (Ins (Int 80)
  End))))))
```

```sh
cat bootstrap/qfasm.qf1 tests/cases/qfasm-exit42.qfasm | bootstrap/seed/qfitzah > exit42
chmod +x exit42 && ./exit42; echo $?   # 42
```

Label names may be arbitrary terms (e.g. `(Local Reader 1)`), since the symbol
table compares keys structurally — giving scoped labels for free. Numbers,
label arithmetic, rel8/rel32 branches, and ELF header fields all work at any
program size, with no finite range tables.

## More examples

The `examples/` directory shows how much can be built on the seed's tiny
rewriter without touching it:

- [byte-assembler.qf1](examples/byte-assembler.qf1) — the machine-code emitter above.
- [arithmetic-compiler.qf1](examples/arithmetic-compiler.qf1) — compiles arithmetic
  expression trees to a continuation-shaped stack-machine program.
- [meta2-arithmetic.qf1](examples/meta2-arithmetic.qf1) — a Meta-II-style parser and
  precedence grammar over a token stream, feeding the stack compiler; shows that
  languages built on the seed need not be S-expression languages.
- [self-hosting-compiler.qf1](examples/self-hosting-compiler.qf1) — a compile-and-run
  pipeline: compiles a small AST to stack bytecode, then runs it in a
  VM written in Qfitzah.
- [tour.qf1](examples/tour.qf1) — a short guided tour of the language.

Run any of them through the seed, e.g. `bootstrap/seed/qfitzah < examples/tour.qf1`.

## Tests

`make check` runs [tests/run.sh](tests/run.sh) against the committed seed. It
covers the seed's rewrite semantics (multi-line records, the rule directive,
repeated pattern variables, structural equality, unmatched template variables,
byte-stream flattening, the example compilers), the Stage 1 assembler against an
independent byte-level model (random 32-bit arithmetic and whole programs
including an 8 KiB, 2868-instruction one, checked byte-for-byte and executed),
the scheme0 interpreter and sc1 compiler over their corpora, the R5RS corpus
through rsc, the sc1 and rsc self-host fixpoints, and then the upper ladder:
building `asm.elf` with its differential and self-fixpoint, the qmes boot ladder
and GC-stress ladder, and the MesCC hello gate.

To run the suite against a freshly built seed instead of the committed one:

```sh
make verify-seed && tests/run.sh build/qfitzah
```
