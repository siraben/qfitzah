# Qfitzah Bootstrap Roadmap

Goal: a real bootstrap ladder from a minimal pattern-matching seed to an
R5RS-to-i386-assembly Scheme compiler that recompiles itself to a byte-identical
fixpoint. Every stage is a real language processor that adds capabilities; no
stage is a proof fixture. Each stage is only as large as it needs to be to make
the next stage comfortable to write — minimal, but correct.

```text
Stage 0  qfitzah.s      seed: pattern-matching term rewriter (hand-audited i386 ELF)
Stage 1  qfasm.qf1      general symbolic/macro assembler (rewrite rules + fact tables)
Stage 2  scheme0.qfasm  minimal Scheme interpreter (macro asm -> native ELF)
Stage 3  sc1.scm        Scheme-subset compiler, written in the scheme0 subset
Stage 4  rsc.scm        R5RS-subset-to-asm compiler, written in the sc1 subset
Fixpoint rsc compiles rsc.scm -> rsc'; rsc' compiles rsc.scm -> rsc''; rsc' == rsc''
```

The prior roadmap grew a swamp of proof fixtures and per-fixture rule overlays
because of two accidental limits, both now understood and removed:

- The seed's input buffer (64 KiB) and atom intern table (1024 entries) capped
  total source size. That was capacity, not capability: the fix is larger
  `.bss` reservations, which cost zero bytes of executable.
- Seed atoms are opaque, so the old assembler could not compute addresses; it
  used finite lookup tables (`N220`, `Addr N221`, ...) that had to be extended
  per fixture. The fix is to represent numbers as nybble lists and do real
  arithmetic with generated fact-table rules, the same move hex0-style
  bootstraps make with opcode tables.

With those two fixes the ladder becomes straight: each stage is general within
its declared subset, so later stages never need per-program overlays.

## Stage 0: Seed (`qfitzah.s`)

A ~1.2 KiB static i386 ELF: S-expression reader, atom interning, newest-first
rewrite rules, structural matching with repeated-variable equality, substitution
preserving unmatched template variables, `(Bytes ...)` byte output, normal
printing. This is the trusted root; it stays hand-audited.

- [x] Correct matching semantics (repeated-variable equality; unmatched
      template variables preserved, not crashing).
- [x] Capacity: input buffer 64 KiB -> 16 MiB, atom table 1024 -> 65536
      entries, larger output buffer. `.bss` only; executable size unchanged.
- [x] Keep the whole existing test suite green after the capacity change.
- [x] Evaluation at scale, measured and fixed twice while keeping semantics:
      `evlis` reuses a pair when neither field changed (sharing instead of
      quadratic copying), and rules are indexed by pattern-head atom in the
      widened intern table (16-byte entries) so inert data no longer scans
      every rule. An 8 KiB / 2868-instruction assembly dropped from 112 s +
      arena exhaustion to 2.5 s. One documented precedence refinement: rules
      whose pattern head is not a constant atom rank below head-indexed ones.
- [ ] (Only if measurement demands it) buffered reads instead of 1-byte
      `read(2)` calls. Semantics must not change.

Philosophy line: the seed gains no new evaluation semantics. Arithmetic,
assembly, and compilation all live above it.

## Stage 1: General Assembler (`bootstrap/qfasm.qf1`)

One assembler written in rewrite rules that replaced the two earlier
finite-table assembler stages and every numeric range overlay. Capability
added: symbolic labels, macros, and real 32-bit arithmetic over programs of
arbitrary size.

- [ ] Number representation: little-endian nybble lists, e.g.
      `(N 4 2 0 1)` for 0x0124. Generated fact tables (committed, produced by
      `tools/generate_qfasm_tables.py`): nybble add/carry, nybble compare, and
      nybble-pair -> byte atom (`(HexByte 4 1)` -> `41`), the latter because
      the seed cannot synthesize new atoms at runtime.
- [ ] 32-bit add/sub/negate/compare over nybble lists; byte-splitting for
      little-endian dword emission.
- [ ] Pass 1: instruction sizes -> label addresses (symbol table as rule
      definitions). Pass 2: emit bytes with resolved rel8/rel32 operands and
      full ELF header arithmetic (entry, segment sizes, padding).
- [x] Scoped labels for free: label names are arbitrary terms (e.g.
      `(Local Reader 1)`) compared structurally in the symbol table. Further
      macro forms (structured conditionals, procedure call forms) get added
      as Stage 2 demands them.
- [ ] Instruction coverage driven by Stage 2's needs (mov/lea/push/pop/alu/
      shifts/cmp/test/jcc/jmp/call/ret/lods/stos/int 0x80), extensible by
      adding rules, never by adding number facts.
- [ ] Tests: assemble exit42; assemble a >4 KiB program (impossible under the
      old N-tables); byte-compare selected outputs against known-good
      binaries.

## Stage 2: Minimal Scheme (`bootstrap/scheme0.qfasm`)

A minimal Scheme interpreter written in Stage 1 macro assembly, assembled under
the seed into a native ELF. Capability added: a real functional programming
language with unbounded arithmetic and data, escaping the rewrite-rule
substrate entirely.

Scope (the scheme0 subset — just enough to write a compiler in):

- [ ] Reader: fixnums, symbols, pairs/lists, `'quote`, strings, characters,
      booleans, comments.
- [ ] Evaluator: `lambda` (proper closures), `define`, `set!`, `if`, `quote`,
      `begin`, `let` (sugar), tail calls that do not grow the stack.
- [ ] Data: pairs, symbols, fixnums, strings, characters, booleans, the empty
      list; vectors optional until Stage 3 needs them.
- [ ] Primitives: `cons car cdr set-car! set-cdr! pair? null? symbol? number?
      string? char? eq? eqv? = < + - * quotient remainder read-char peek-char
      write-char display newline error exit` (list finalized by what sc1
      needs).
- [ ] Memory: bump allocator over a large arena first; a simple two-space
      collector is a follow-up, not a blocker (the compiler runs are
      short-lived, same argument the seed makes).
- [ ] Tests: run small Scheme programs (append, map, assoc, recursion depth via
      tail calls) under the assembled interpreter.

## Stage 3: Scheme Compiler in Scheme (`bootstrap/sc1.scm`)

A compiler written strictly in the scheme0 subset. It compiles the larger sc1
subset to Stage 1 assembler source; the seed assembles that to a native ELF.
Capability added: compiled (fast, native) Scheme, plus the language extensions
a serious compiler wants.

- [ ] Language of its input (sc1 subset): scheme0 subset plus `letrec`, named
      `let`, `cond`, `case`, `and`, `or`, `when`/`unless`, multi-body lambdas,
      vectors, `string->symbol`/`symbol->string`, `char->integer`/
      `integer->char`, proper `write`.
- [ ] Compilation model: closure conversion, flat environments, tagged
      immediates (fixnum/char/bool/nil), heap-allocated pairs/strings/vectors/
      closures, direct-style code generation with proper tail calls.
- [ ] Emits qfasm source (Stage 1 is the system assembler for every later
      stage).
- [ ] Bootstrap step: scheme0 interprets sc1.scm compiling sc1.scm ->
      sc1.elf. From then on the interpreter leaves the hot path.
- [ ] Tests: sc1.elf output equals interpreted-sc1 output on a program corpus;
      sc1.elf compiles sc1.scm again to a byte-identical sc1'.

## Stage 4: R5RS Compiler (`bootstrap/rsc.scm`)

The target: an R5RS-to-asm compiler written in the sc1 subset, compiled by
sc1.elf, then self-hosted. Capability added: the R5RS surface language —
`define-syntax`/`syntax-rules`, `quasiquote`, full numeric tower for exact
integers (bignums), floats optional/documented-out, `call/cc` (escape-only
acceptable if documented), dynamic-wind, ports, `apply`, varargs, `values`,
proper `equal?`/`assoc`/`member` family, string/vector/char library, `eval`
over the compiled subset.

- [ ] Front end: `syntax-rules` macro expander lowering R5RS to a small core.
- [ ] Middle: CPS or ANF core with assignment conversion and closure
      conversion.
- [ ] Back end: i386 asm through qfasm, Linux `int $0x80` I/O runtime, precise
      or conservative GC (a real collector lands here, where the language can
      afford to express one).
- [ ] Bootstrap: sc1.elf compiles rsc.scm -> rsc.elf.
- [ ] Fixpoint: rsc.elf compiles rsc.scm -> rsc2.elf; rsc2.elf compiles
      rsc.scm -> rsc3.elf; `cmp rsc2.elf rsc3.elf` byte-identical.
- [ ] Tests: an R5RS conformance corpus (subset documented), plus the fixpoint
      check wired into `tests/run.sh`.

## Retirement of the Old Proof Fixtures

The old proof fixtures and overlays demonstrated subsystem mechanics (GC
copying, forwarding, dispatch, printing) under the old limits. They, their
generators, and their test plumbing have been deleted; git history holds
them. Their lessons live on as requirements in Stages 2-4 (GC -> Stage 4
runtime; dispatch/printing -> Stages 2-3; byte output -> Stage 1, done).

## Verification Discipline

- Every stage's artifact is produced by running the previous stage, never by a
  host toolchain. Host tools (python3) may generate *source* fact tables and
  test fixtures, but never object bytes.
- Byte-identical checks at every boundary that has one: seed binary vs
  `new.s`-style self-description, sc1 self-compilation, rsc fixpoint.
- `tests/run.sh` stays the single entry point; each stage adds its ladder test
  the moment it can run end to end.
