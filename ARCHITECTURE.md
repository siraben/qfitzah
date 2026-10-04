# Architecture

```text
Stage 0  qfitzah.s      term rewriter (i386 ELF)
Stage 1  qfasm.qf1      symbolic assembler (rewrite rules)
Stage 2  scheme0.qfasm  Scheme interpreter (qfasm -> ELF)
Stage 3  sc1.scm        Scheme compiler, written in the scheme0 subset
Stage 4  rsc.scm        R5RS-subset compiler, written in the sc1 subset
```

GNU binutils builds the seed. The seed runs the assembler at every stage.
The assembled scheme0 interpreter runs sc1; compiled sc1 builds rsc.
Assembler and runtime sources are edited directly. Source macros run in Qfitzah.

## Stage 0: Seed (`qfitzah.s`)

The seed is a 2,148-byte static i386 Linux executable. It reads S-expressions,
interns atoms, stores rewrite rules, matches and substitutes terms, and prints
normal forms or emits bytes. It supports dotted tails and repeated-variable
structural equality. Unmatched template variables remain unchanged.

Rules with a constant head are indexed by that atom and take priority over
generic rules. Within either group, the newest matching rule wins.

Pairs are immutable and never freed. `evlis` reuses a pair when neither field
changes. A direct-mapped cache stores normal forms by pair address; adding a
rule increments a generation counter to invalidate cached results. Collisions
cause recomputation.

`Bytes` accepts two-digit hex atoms and `(Hex high low)` terms. The seed
validates each record before flushing its bytes. Malformed records and byte
terms exit with status 1 and a stderr diagnostic. Earlier records may already
have been written, so callers must discard stdout on failure.

## Stage 1: Assembler (`bootstrap/qfasm.qf1`)

Numbers are little-endian nybble lists, `(N d0 ... d7)`. Eight full-adder rules
implement bit addition; four applications add a nybble. Register encodings,
complement and alignment operate on bit fields. Zero-add rules avoid expanding
unused high digits. `(HB hi lo)` produces `(Hex hi lo)`.

Each instruction has a `Describe` rule:

```text
(Describe (MovRI r x)) (Encoding ((B (MovIB r)) (W (Lit x))))
(Describe (Call label)) (Encoding ((B E8) (W (Relative label))))
```

Fields have fixed widths: `B` is one byte, `W` four bytes, and `R` a checked
relative byte. `Lit`, `Abs`, `Tagged` and `Relative` defer operand resolution.
`Prepare` computes instruction widths and stores the fields. `LayoutPass`
returns the symbol table and total size. `EmitCode` resolves relative operands
from the end of the whole instruction. Alignment is code-relative.

Descriptors are limited to 15 bytes. A `B` field rejects nested byte streams.
Unknown instructions, labels, registers and unsupported addressing modes leave
unresolved terms under `Bytes`, which the seed rejects. ESP bases requiring
SIB and mod=00 EBP bases requiring disp32 are unsupported. Byte-register
encodings 4–7 select AH/CH/DH/BH.

Programs have the form `(Assemble (Program entry bss code))`; omitting `bss`
selects zero extra memory. Instructions form an `(Ins instr ... End)` chain.
Label names are arbitrary terms compared structurally, such as `(Local Reader 1)`.
The ELF has one RWE load segment; `bss` adds zero-initialized memory after the
file data.

Add an instruction's descriptor and its expected bytes to
`tests/cases/instruction-encodings.tsv`. The test checks descriptor coverage,
encoded bytes and width.

## Shared assembly macros (`bootstrap/runtime-support.qf1`)

Load `qfasm.qf1`, then `runtime-support.qf1`, then the runtime or program:

```sh
cat bootstrap/qfasm.qf1 bootstrap/runtime-support.qf1 bootstrap/scheme0.qfasm \
  | result/bin/qfitzah > scheme0.elf
chmod +x scheme0.elf
```

`Block` folds a list of instructions into an `Ins` chain with a supplied
continuation. `Splice` inserts another instruction list and may nest:

```text
(Block ((MovRI EAX (Small 1)) (Splice ((Nop) (Ret)))) End)
```

`(Prim name code spelling)` declares a primitive. `ForPrimitives` expands these
into interpreter bindings, compiled closures, global cells or name bytes.
`SpecialForms` supplies scheme0 initialization, dispatch and name data.
`PrimitiveEntry`, `ReturnBoolean` and `ComparePrimitive` provide code templates.

Spelling is explicit: `(C O N S)` encodes lowercase ASCII `cons`. The token list
determines both length and bytes; names have no NUL terminator or padding.
When changing primitives, also update the compiler's `prim-names` list and keep
each name's spelling consistent. `eq?` and `eqv?` have separate global cells
but share the `PrEqQ` entry point.

## Stage 2: Interpreter (`bootstrap/scheme0.qfasm`)

scheme0 is written in flat assembly using the shared macros. Its reader handles
fixnums, symbols, pairs, dotted pairs, quote, strings, characters, booleans and
comments. The evaluator implements closures, rest parameters, `define`, `set!`,
`if`, `quote`, `begin`, `let`, `cond`, `and`, `or` and tail calls. Primitives cover
pairs, fixnum arithmetic, comparisons, characters, strings, symbols and I/O.

### Runtime representation

Words use low tags 00=pair, 01=fixnum, 10=object, 11=immediate. Object subtypes
are 0=symbol, 1=string, 2=closure, 3=primitive and (rsc) 4=vector. Symbol/string
cells hold a tagged byte pointer and fixnum length; vector elements are words.
An interpreted closure holds `(params . (body . env))`; a compiled closure
holds `(code . env)`.

Immediate words are nil `03`, true `13`, false `23`, EOF `33` and unspecified
`43`. Characters use `(code << 8) | 53`. Assembler `DNil` emits `01`, not Scheme
nil. `DObj`/`MovRIObj` add tag 2; `DConst`/`MovRIConst` add tag 1.

Compiled calls pass arguments in EAX and the captured environment in EDI.
EBP holds the environment frame chain. `Cons` preserves ECX/EDX;
`ReadCh`, `PeekCh` and `Emit` preserve EBX/ECX/EDX; `PrintRaw` clobbers EAX/EBX.
scheme0 primitive entries are 8-byte-aligned to allow tagged code addresses.
Compiled closures hold raw code addresses.

The runtimes reserve 256 MiB of BSS. After aligning `CodeEnd` to 8 bytes,
allocation partitions it into 192 MiB of cells, 32 MiB of bytes, a 16 MiB read
buffer and token space. `GObList` and scheme0's `GEnv` start as Scheme nil,
`GPeek` as all ones, and other globals as zero.

## Stage 3: Compiler (`bootstrap/sc1.scm`)

sc1 compiles the scheme0 subset to qfasm. It uses `sc1-reader.scm` and the
`sc1-runtime.qf1` assembly runtime, expanded through `RuntimeCode` and
`RuntimeData` macros.

Lexical variables compile to `(depth, index)` frame walks; globals use static
cells. Quoted structures become static data, with quoted symbols interned at
startup. Direct tail applications use JMP; non-tail applications use CALL.

scheme0 runs sc1 to compile itself. The resulting native compiler recompiles
`sc1-reader.scm` and `sc1.scm`. The tests compare both assembly text and complete
ELFs, then use the rebuilt compiler to compile and run the corpus.

## Stage 4: R5RS-subset compiler (`bootstrap/rsc.scm`)

rsc adds a macro-expansion pass before sc1's code generator and uses
`rsc-runtime.qf1`. It supports `syntax-rules`, quasiquote, derived forms
(`let*`, `letrec`, named `let`, `case`, `when`, `unless`, `do`, `cond =>`), vectors
and tail `apply`. The caller prepends `rsc-prelude.scm` for list, integer,
character and string library procedures.

sc1 compiles rsc to `rscA`; A compiles rsc to B; B compiles rsc to C. Tests
compare the B/C assembly text and complete ELFs, and run the feature corpus
through A and C. rsc itself is written in the sc1 subset, so its self-compilation
does not exercise the added language features.

## Limits and known bugs

Memory arenas and stacks are finite, with mostly unchecked bounds. Short writes
and I/O errors are not fully handled. There is no garbage collector.

The Scheme implementations have these known bugs:

- Some in-range fixnum literals are misencoded. Internal definitions affect
  globals; test-only `cond` clauses lose their value. Comparisons ignore extra
  operands, and printed strings lack escaping.
- Macro renaming does not provide full lexical hygiene. Definition-site
  references, quoted identifiers, literal bindings and string patterns have
  incorrect cases. Nested quasiquote splicing is also incomplete.
- `apply` can mutate the caller's argument-list cells when binding parameters.
- Compiled `and`/`or` lose tail position.

Unsupported features include bignums, floats, rationals, `call/cc`,
`dynamic-wind`, first-class `eval`, `delay`/`force` and vector read syntax.

## Tests

`nix flake check` runs `tests/run.sh` with the seed and source files. It checks
rewrite semantics, byte output, assembly, the Scheme corpora and compiler
fixpoints. `tests/boundaries.sh` covers all bytes, nybble sums and supported
register encodings, plus malformed input. Other scripts check instruction
widths, layout, branch ranges and source macros.

`tests/probe-semantics.sh` tests the known Scheme bugs separately and exits
nonzero on failures. `tests/bootstrap-artifacts.sh SEED OUTPUT_DIR [SOURCE_ROOT]`
builds scheme0, sc1, rscA and rscB and prints their hashes; the output directory
must not exist.
