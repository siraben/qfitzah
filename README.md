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

[bootstrap/stage1-multiline-rules.qf1](bootstrap/stage1-multiline-rules.qf1)
is the first Qfitzah-improved bootstrap fixture. It uses only the improved
reader feature: readable multi-line `(Rule pattern replacement)` records. The
test suite runs that bootstrap file directly so later staged sources have a
checked base for multi-line rules.

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
- `(Call label)` computes a signed direct call displacement for the bootstrap range
- ELF `p_filesz`/`p_memsz` are selected from the assembled code size

The current implementation intentionally uses finite arithmetic and layout
tables for the small bootstrap range; later stages should replace those tables
with generated arithmetic and richer macros. The layout range is large enough
for the current static object examples.

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
assembly. Its rules and sample input are written as multi-line forms with the
explicit `(Rule pattern replacement)` directive. The current macro layer
supports:

- `(Proc name clobbers body)` procedure blocks
- scoped local labels represented as `(Local proc name)`
- `(IfZero name then else)` structured conditionals
- `(Invoke name args)` call setup for register arguments
- `(TailCallProc name)` procedure jumps for tail-recursive loops
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
hands the result to qfasm3/qfasm2. The compiler rules are written with the
multi-line `(Rule pattern replacement)` directive so the staged compiler source
itself exercises the improved reader.

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

[bootstrap/stage4-nybble.qf1](bootstrap/stage4-nybble.qf1) is the first
runtime-subsystem target. It compiles the `nybble` logic from `qfitzah.s` into
the staged language pipeline:

```text
load byte from static data
call Nybble
subtract '0'
compare with 9
conditionally subtract 7
exit with the computed value
```

For input byte `41` (`A`), the generated ELF exits with status `10`.

[bootstrap/stage4-emit-byte.qf1](bootstrap/stage4-emit-byte.qf1) compiles the
next byte-output step. It reads two static ASCII hex digits, calls `Nybble` for
each, combines the high and low nybbles into a byte, and invokes Linux
`write(1, sp, 1)` to emit that byte. The generated ELF writes byte `41`
(`A`) to stdout and exits with status `0`.

[bootstrap/stage4-emit-bytes.qf1](bootstrap/stage4-emit-bytes.qf1) compiles a
recursive `EmitBytes`-shaped routine. It keeps a byte pointer in `ECX`, a count
in `EDX`, writes the current byte, advances the pointer, decrements the count,
and recursively calls itself until the count reaches zero. The generated ELF
writes bytes `41 42 43 44 45` (`ABCDE`). This example requires qfasm2 to encode
a signed backward call displacement.

[bootstrap/stage4-emit-bytes-object.qf1](bootstrap/stage4-emit-bytes-object.qf1)
compiles the next byte-output slice over static Qfitzah-shaped objects. It
builds an aligned tagged object for `(Bytes 41)`, checks the `Bytes` head atom,
takes the cdr, recursively walks the cons-list tail, decodes the `41` atom, and
writes byte `41`. This proves static pair cells, tagged atom pointers, nil,
field loads, and aligned data emission in the staged compiler pipeline.

[bootstrap/stage4-emit-bytes-nested.qf1](bootstrap/stage4-emit-bytes-nested.qf1)
focuses on nested `Bytes` flattening over static objects. It builds
`(Bytes (Bytes 41))`, checks the list element with `IsBytes`, takes the nested
object's cdr, recursively emits that tail, and writes byte `41`.

[bootstrap/stage4-emit-bytes-general.qf1](bootstrap/stage4-emit-bytes-general.qf1)
combines cons-tail traversal and nested `Bytes` flattening in one compiled
`EmitBytes` routine. It uses `TailCallProc` for the recursive outer-list loop
and emits static `(Bytes (Bytes 41))` as byte `41`.

[bootstrap/stage4-is-bytes-content.qf1](bootstrap/stage4-is-bytes-content.qf1)
compiles the closer `is_bytes` check from `qfitzah.s`: it recognizes a `Bytes`
head atom by length and character contents rather than by pointer identity. Its
extra comparison rules are local to that fixture to keep the common staged
compiler small enough for the seed runtime.
[bootstrap/stage4-is-bytes-content-reject.qf1](bootstrap/stage4-is-bytes-content-reject.qf1)
uses the same compiled check with a `Bytez` head atom and exits with status `1`,
covering the negative path. [bootstrap/source-size-budget.md](bootstrap/source-size-budget.md)
records the current seed-runtime limit for larger combinations.
[bootstrap/stage4-is-bytes-content-output.qf1](bootstrap/stage4-is-bytes-content-output.qf1)
uses content-based `IsBytes` to gate real byte output for static `(Bytes 41)`.
[bootstrap/stage4-is-bytes-content-linear.qf1](bootstrap/stage4-is-bytes-content-linear.qf1)
compiles the same byte-output path with explicit scoped local labels and
fail-fast `jnz` branches, proving a smaller control-flow shape for runtime
predicates without adding those branch forms to the common compiler source.
[bootstrap/qfc4-byte-output.qf1](bootstrap/qfc4-byte-output.qf1) and
[bootstrap/qfasm-byte-output-ext.qf1](bootstrap/qfasm-byte-output-ext.qf1)
split that path into a direct byte-output compiler slice plus a small optional
assembler extension. [bootstrap/stage4-is-bytes-content-linear-direct.qf1](bootstrap/stage4-is-bytes-content-linear-direct.qf1)
uses those split stages and emits the same byte `41`.
[bootstrap/qfasm2-exit42-n221.qf1](bootstrap/qfasm2-exit42-n221.qf1)
checks the first optional code-size extension past the common `N220` boundary:
it emits a 221-byte code segment and exits with status `42`.
[bootstrap/qfasm2-entry-n221.qf1](bootstrap/qfasm2-entry-n221.qf1)
then puts the ELF entry label at offset `N221`, proving optional `Addr N221`
emission for a runnable binary.
[bootstrap/stage5-pair-allocation.qf1](bootstrap/stage5-pair-allocation.qf1)
is the first mutable pair-construction slice. It uses
[bootstrap/qfasm-heap-ext.qf1](bootstrap/qfasm-heap-ext.qf1) to add dword
stores and a writable executable segment, plus
[bootstrap/qfc4-heap-ext.qf1](bootstrap/qfc4-heap-ext.qf1) to expose those
operations to qfc4. The generated ELF writes a pair cell into a static heap
area, reads the car field back, and exits with status `42`.
[bootstrap/stage5-bump-alloc.qf1](bootstrap/stage5-bump-alloc.qf1) advances
that into a bump-pointer proof: it loads a `HeapNext` cell, constructs one
pair, stores the advanced pointer, constructs a second pair through the updated
pointer, then exits with the first pair's car (`19`) to prove the second
allocation did not overwrite it.
[bootstrap/stage5-alloc-proc.qf1](bootstrap/stage5-alloc-proc.qf1) factors the
same behavior into a reusable compiled `AllocPair` procedure. Callers pass car
in `EBX` and cdr in `ECX`; the procedure writes the pair, bumps `HeapNext` by
eight bytes, returns the allocated pair in `EAX`, and the checked program calls
it twice.
[bootstrap/stage5-alloc-checked.qf1](bootstrap/stage5-alloc-checked.qf1) and
[bootstrap/stage5-alloc-overflow.qf1](bootstrap/stage5-alloc-overflow.qf1)
add the first allocator bounds-check proof at the qfasm2 layer. The success
case checks `HeapNext + 8 <= HeapLimit` before storing a pair and exits `19`;
the overflow case starts `HeapNext` at `HeapLimit` and exits `7` before
committing the bump or storing fields.
[bootstrap/stage5-alloc-checked-qfc4.qf1](bootstrap/stage5-alloc-checked-qfc4.qf1)
and
[bootstrap/stage5-alloc-overflow-qfc4.qf1](bootstrap/stage5-alloc-overflow-qfc4.qf1)
lift that first bounds-check path back through qfc4. The staged source now
expresses the `HeapNext + 8 <= HeapLimit` branch, and the generated ELFs cover
both commit (`19`) and overflow (`7`).
[bootstrap/stage5-alloc-reset-gc.qf1](bootstrap/stage5-alloc-reset-gc.qf1)
adds the first recovery policy proof: on overflow it resets `HeapNext` to the
heap base, retries the allocation, stores a pair, and exits `19`. This models a
minimal no-live-objects collection pass at the qfasm2 level.
[bootstrap/stage5-alloc-reset-gc-qfc4.qf1](bootstrap/stage5-alloc-reset-gc-qfc4.qf1)
lifts that reset/retry recovery through qfc4: staged source now performs the
overflow branch, rewrites `HeapNext` to `Heap`, retries allocation, and exits
with the recovered pair car (`19`).
[bootstrap/stage5-copy-root-gc.qf1](bootstrap/stage5-copy-root-gc.qf1) extends
that recovery path to one live root: it copies the root pair into the reset
heap, updates the root slot, allocates another pair after it, and exits with
the copied root car (`19`).
[bootstrap/stage5-copy-root-gc-qfc4.qf1](bootstrap/stage5-copy-root-gc-qfc4.qf1)
lifts the root-copy/update mechanics through qfc4. The staged source copies
`Root` into `Heap`, rewrites the root slot, advances `HeapNext`, allocates
after the copied root, and exits with the copied car (`19`).
[bootstrap/stage5-copy-graph-gc.qf1](bootstrap/stage5-copy-graph-gc.qf1)
extends that proof to a two-pair graph: the root pair's cdr points at a second
pair, recovery copies both cells, rewrites the copied cdr to the new tail, then
allocates after the copied graph. The generated ELF exits with the copied tail
car (`19`). The old tail is deliberately reused for the retry allocation and
overwritten with `42`, so a missed cdr rewrite is observable.
[bootstrap/qfc4-copy-ext.qf1](bootstrap/qfc4-copy-ext.qf1) and
[bootstrap/stage5-copy-graph-gc-qfc4.qf1](bootstrap/stage5-copy-graph-gc-qfc4.qf1)
lift that fixed graph-copy proof through qfc4 with compact staged copy
statements.
[bootstrap/stage5-copy-list-gc.qf1](bootstrap/stage5-copy-list-gc.qf1)
replaces that fixed-shape copy with a loop over a nil-terminated pair list. It
uses a `LinkSlot` cell to thread the root slot and copied cdr fields, copies a
three-pair list until nil, overwrites the old tail, allocates after the copied
list, and exits with the copied tail car (`19`).
[bootstrap/qfc4-list-copy-ext.qf1](bootstrap/qfc4-list-copy-ext.qf1) and
[bootstrap/stage5-copy-list-gc-qfc4.qf1](bootstrap/stage5-copy-list-gc-qfc4.qf1)
lift that traversal through qfc4. The test runs it as a two-step Qfitzah
pipeline, qfc4 to qfasm3 source and then qfasm3/qfasm2 to ELF, to avoid loading
all optional Stage 5 rules into the seed runtime at once.
[bootstrap/stage5-copy-nested-pair-gc.qf1](bootstrap/stage5-copy-nested-pair-gc.qf1)
starts moving beyond list-only traversal: the root's car is itself a pair, so
recovery must detect and copy that child pair, rewrite the copied car edge,
overwrite the old child, and still exit with the copied child car (`19`).
[bootstrap/stage5-copy-two-field-object-gc.qf1](bootstrap/stage5-copy-two-field-object-gc.qf1)
extends that to both fields of one object: `car` and `cdr` are live pair edges,
both are copied and rewritten, and stale edges are observable as distinct exit
statuses before the copied cdr child exits `23`.
[bootstrap/qfc4-object-copy-ext.qf1](bootstrap/qfc4-object-copy-ext.qf1),
[bootstrap/qfc4-object-data-ext.qf1](bootstrap/qfc4-object-data-ext.qf1), and
[bootstrap/stage5-copy-two-field-object-gc-qfc4.qf1](bootstrap/stage5-copy-two-field-object-gc-qfc4.qf1)
lift that two-field object proof through qfc4. The fixture keeps data before
code so the finite address table remains valid, then runs as a staged qfc4 to
qfasm3 source and qfasm3/qfasm2 to ELF pipeline.
[bootstrap/stage5-copy-tree-gc.qf1](bootstrap/stage5-copy-tree-gc.qf1) is the
next lower-level GC baseline: it scans copied pairs from `Scan` up to
`HeapNext`, copies any pair-valued `car` or `cdr` field it discovers, rewrites
the field to the copied child, and resumes allocation after a five-cell copied
tree. It handles acyclic pair trees, not sharing or cycles yet.
[bootstrap/qfc4-scan-copy-ext.qf1](bootstrap/qfc4-scan-copy-ext.qf1) and
[bootstrap/stage5-copy-tree-gc-qfc4.qf1](bootstrap/stage5-copy-tree-gc-qfc4.qf1)
lift that scan-copy traversal through qfc4. The generated ELF has the same
observable result (`35`), with local near-branch/range support for the scan
loop backedge.
[bootstrap/stage5-forwarding-gc.qf1](bootstrap/stage5-forwarding-gc.qf1) starts
the forwarding-pointer work needed for shared graphs. It copies a root whose
`car` and `cdr` both point at the same old pair, installs a temporary
forwarding marker in the old pair, rewrites both copied fields to the single
new child, and checks pointer equality plus `HeapNext` before exiting with the
copied child car (`19`). This proves one shared acyclic pair, not cycles or a
general Qfitzah object forwarding format yet.
[bootstrap/qfc4-forwarding-ext.qf1](bootstrap/qfc4-forwarding-ext.qf1),
[bootstrap/qfasm-stage5-forwarding-ext.qf1](bootstrap/qfasm-stage5-forwarding-ext.qf1),
and [bootstrap/stage5-forwarding-gc-qfc4.qf1](bootstrap/stage5-forwarding-gc-qfc4.qf1)
lift the same focused sharing proof through qfc4 using a two-step qfc4 to
qfasm3, then qfasm3/qfasm2 to ELF pipeline.
[bootstrap/stage5-forwarding-cycle-gc.qf1](bootstrap/stage5-forwarding-cycle-gc.qf1)
extends forwarding to a one-pair cycle: the old root's `car` points back to the
old root, recovery copies it once, marks the old object forwarded, rewrites the
copied `car` to the copied object itself, overwrites the old object, and exits
through the copied self-cycle (`23`). The qfc4 lift uses separate optional
cycle-forwarding extension files so the seed runtime does not load unrelated
sharing rules for that staged test.
[bootstrap/stage5-scan-forwarding-gc.qf1](bootstrap/stage5-scan-forwarding-gc.qf1)
combines the scan traversal and forwarding paths at the qfasm2 layer. A root
has two fields pointing at one child, and that child points to itself; the scan
copies the child once, rewrites both root fields and the self-edge to the new
cell, checks `HeapNext`, then exits through the copied child car (`19`).
[bootstrap/stage5-scan-forwarding-complex-gc.qf1](bootstrap/stage5-scan-forwarding-complex-gc.qf1)
uses the same scan-forwarding machinery on a larger mixed graph: root points to
two different children, both children converge on one shared self-cyclic node,
and the shared node carries a tagged static atom. The generated ELF verifies
the shared identity, self-cycle, atom preservation, and four-cell copy frontier
after overwriting every old pair object.
[bootstrap/stage5-scan-forwarding-complex-gc-qfc4.qf1](bootstrap/stage5-scan-forwarding-complex-gc-qfc4.qf1)
lifts that mixed graph through qfc4 with a separate
`qfc4-scan-forwarding-complex-ext.qf1` and a tiny tagged-constant comparison
assembler extension, keeping the staged source readable without increasing the
simpler qfc4 scan-forwarding test's rule load.
[bootstrap/stage5-scan-forwarding-dynamic-atom-gc.qf1](bootstrap/stage5-scan-forwarding-dynamic-atom-gc.qf1)
combines forwarding with runtime atom copying at the direct qfasm2 layer. A
copied child has its self-cycle rewritten through a forwarding marker, and its
runtime-initialized cdr atom is copied into the atom frontier before all old
records are overwritten.
[bootstrap/stage5-scan-forwarding-dynamic-atom-gc-qfc4.qf1](bootstrap/stage5-scan-forwarding-dynamic-atom-gc-qfc4.qf1)
lifts that combined forwarding-plus-atom proof through qfc4 with
`qfc4-scan-forwarding-dynamic-atom-ext.qf1`. The staged test reuses the split
branch pass-through shim for the short branches in the focused scan handlers
and verifies a runnable ELF with exit status `0`.
[bootstrap/stage5-checked-scan-forwarding-dynamic-atom-gc.qf1](bootstrap/stage5-checked-scan-forwarding-dynamic-atom-gc.qf1)
connects checked allocation to that collector shape: the first allocation
starts at `HeapLimit`, overflows, runs scan-forwarding recovery with runtime
atom copying, retries after the copied graph, and verifies the retry pair
without overwriting copied live data.
[bootstrap/stage5-checked-scan-forwarding-dynamic-atom-gc-qfc4.qf1](bootstrap/stage5-checked-scan-forwarding-dynamic-atom-gc-qfc4.qf1)
lifts that checked overflow/recovery/retry path through qfc4 with focused
qfc4/qfasm extensions, so the staged compiler surface now covers the allocator
boundary and the collector shape together.
[bootstrap/stage5-dispatch-table-qfc4.qf1](bootstrap/stage5-dispatch-table-qfc4.qf1)
starts the multiple-dispatch-table path. qfc4 compiles two table entries with
two-argument signature records and concrete method pointers; runtime dispatch
skips the first non-matching entry, loads the matching method pointer, calls it
indirectly, and exits with status `42`.
[bootstrap/stage5-scan-forwarding-gc-qfc4.qf1](bootstrap/stage5-scan-forwarding-gc-qfc4.qf1)
lifts the same scan-forwarding graph through qfc4. Its qfc4 source keeps the
loop readable and uses `qfc4-scan-forwarding-ext.qf1` for the long field
handlers, then assembles with the split wide-branch qfasm extension.
[bootstrap/stage5-copy-bytes-output-gc.qf1](bootstrap/stage5-copy-bytes-output-gc.qf1)
connects recovery to byte output at the direct qfasm2 layer. It forces
recovery, copies a static `(Bytes 41)` object graph, overwrites the old pair
objects, then runs the copied byte atom through `EmitByte`, `Nybble`, and
`write(2)`; the generated ELF writes byte `41` and exits `0`.
[bootstrap/stage5-copy-bytes-isbytes-output-gc.qf1](bootstrap/stage5-copy-bytes-isbytes-output-gc.qf1)
adds the runtime `IsBytes` gate after recovery. The copied head atom is named
separately and recognized by length and character contents, then the copied
tail is emitted as byte `41`.
[bootstrap/stage5-copy-nested-bytes-output-gc.qf1](bootstrap/stage5-copy-nested-bytes-output-gc.qf1)
extends that direct recovered-output path to `(Bytes (Bytes 41))`. Recovery
copies the outer list cell, inner `Bytes` object, and inner byte tail, clobbers
all old pairs, then recursive `EmitBytes` recognizes both `Bytes` atoms by
content and flattens the copied nested object to stdout byte `41`.
[bootstrap/stage5-copy-bytes-isbytes-output-gc-qfc4.qf1](bootstrap/stage5-copy-bytes-isbytes-output-gc-qfc4.qf1)
lifts that content-checked recovery/output path through qfc4 with
`qfc4-copy-bytes-isbytes-output-ext.qf1` and `qfasm-byte-output-ext.qf1`.
[bootstrap/stage5-copy-nested-bytes-output-gc-qfc4.qf1](bootstrap/stage5-copy-nested-bytes-output-gc-qfc4.qf1)
lifts the copied nested-byte proof through qfc4 with
`qfc4-copy-nested-bytes-output-ext.qf1`. The staged source keeps recursive
`EmitBytes`, content-based `IsBytes`, `EmitByte`, and `Nybble` readable, then
the generated ELF prints stdout byte `41`.
[bootstrap/stage5-copy-dynamic-atoms-output-gc.qf1](bootstrap/stage5-copy-dynamic-atoms-output-gc.qf1)
starts moving atoms out of static data. It initializes the `Bytes` and `41`
atom records in writable cells at runtime, copies tagged atom fields into a
separate atom frontier during recovery, overwrites the old atom records, then
recognizes the copied `Bytes` atom by content and emits byte `41`.
[bootstrap/stage5-copy-dynamic-atom-cdr-gc.qf1](bootstrap/stage5-copy-dynamic-atom-cdr-gc.qf1)
extends the same atom frontier to a tagged atom in a pair `cdr`. It rewrites
the copied cdr to the copied atom, overwrites the old atom record, then emits
byte `41` from the copied cdr atom.
[bootstrap/stage5-copy-dynamic-atom-fields-gc.qf1](bootstrap/stage5-copy-dynamic-atom-fields-gc.qf1)
combines those paths in one scan: a copied pair has runtime-initialized tagged
atoms in both `car` and `cdr`, both fields are rewritten to copied atom records,
the old atoms are overwritten, and stdout still comes from the copied cdr atom.
[bootstrap/stage5-copy-dynamic-atom-fields-gc-qfc4.qf1](bootstrap/stage5-copy-dynamic-atom-fields-gc-qfc4.qf1)
lifts that combined dynamic atom-field proof through qfc4 with
`qfc4-copy-dynamic-atom-fields-ext.qf1`. Its staged test uses the small
`qfasm-stage5-branch-ext.qf1` shim to pass direct short-branch scan snippets
through qfasm3, then checks the exact ELF and stdout byte `41`.
[bootstrap/stage5-copy-dynamic-atom-nested-gc-qfc4.qf1](bootstrap/stage5-copy-dynamic-atom-nested-gc-qfc4.qf1)
extends that qfc4 path beyond the root object: recovery copies a root pair,
the scan then discovers a child pair, and only when the child is scanned is its
runtime-initialized cdr atom copied into the atom frontier and verified after
the old records are overwritten.
[bootstrap/stage5-copy-dynamic-atom-deep-gc-qfc4.qf1](bootstrap/stage5-copy-dynamic-atom-deep-gc-qfc4.qf1)
extends the same proof across multiple scan iterations: root, child, and
grandchild pairs are copied in order, then the grandchild's runtime-initialized
cdr atom is copied when traversal reaches that grandchild.
[bootstrap/stage5-copy-bytes-output-gc-qfc4.qf1](bootstrap/stage5-copy-bytes-output-gc-qfc4.qf1)
lifts the same GC-plus-byte-output proof through qfc4 using
`qfc4-copy-bytes-output-ext.qf1` plus the existing scan-copy extension. Its
test checks both the exact generated ELF and runtime stdout `41`.
The Stage 4 sample programs are also formatted as multi-line Qfitzah forms.

## Tests

```sh
nix flake check
```

The test suite covers basic rewriting, fast multi-line piped input, final
multi-line records at EOF, the Stage 1 multi-line-rule bootstrap fixture,
repeated pattern variables, structural equality for repeated list-valued
variables, unmatched template variables, reader ergonomics, empty-list
matching, nested byte-stream flattening, the example compilers, the
Qfitzah-hosted assembler stages, runnable Stage 4 byte-output runtime slices,
and the current Stage 5 mutable allocation, recovery, scan-copy, and forwarding
slices.
Test programs live in
`tests/cases/*.qf1`, with expected snippets in matching `.expected` files and
forbidden snippets in optional `.unexpected` files.

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
