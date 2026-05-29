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
- byte loads, byte stores through `write(2)`, small register arithmetic, and
  frame-preservation requests for the bootstrap byte-output path

That is enough to prove the staged assembler/compiler pipeline, but not enough
to compile the interpreter.

## Next Concrete Milestone

The next milestone should be a `qfitzah-runtime.qfc4` or successor source file
that incrementally reimplements one real runtime subsystem at a time. A useful
first target is the byte-output path because it is small but real:

```text
is_bytes + emit_bytes + emit_byte + nybble
```

Progress so far:

- `stage4-nybble.qf1` compiles the `nybble` routine shape through qfc4,
  qfasm3, and qfasm2 into a runnable ELF.
- The compiled program loads byte `A` from static data, calls `Nybble`,
  performs the subtract/compare/conditional-subtract sequence, and exits with
  status `10`.
- `stage4-emit-byte.qf1` compiles the next routine shape: load two ASCII hex
  digits, call `Nybble` twice, combine high/low nybbles, and write one byte to
  stdout. The generated ELF writes byte `41` (`A`) and exits with status `0`.
- `stage4-emit-bytes.qf1` compiles a recursive `EmitBytes`-shaped byte-span
  walker. It loads bytes through `ECX`, preserves `ECX` and `EDX` around
  `write(2)`, decrements a count in `EDX`, and performs a backward recursive
  call until the count reaches zero. The generated ELF writes `ABCDE`.
- `stage4-emit-bytes-object.qf1` compiles a static tagged `(Bytes 41)` object
  and emits it through a closer byte-output path: check the `Bytes` head atom,
  take the cdr, recursively walk the cons-list tail, load the atom character
  pointer, decode the hex atom, and write byte `41`.
- `stage4-emit-bytes-nested.qf1` compiles a focused nested fixture,
  `(Bytes (Bytes 41))`. It checks a list element with `IsBytes`, recognizes the
  nested `Bytes` object, takes its cdr, recursively emits the nested tail, and
  writes byte `41`.
- `stage4-emit-bytes-general.qf1` combines cons-tail traversal and nested
  `Bytes` flattening in one compiled `EmitBytes` routine. It uses
  `TailCallProc` for the recursive outer-list loop and emits static
  `(Bytes (Bytes 41))` as byte `41`.
- `stage4-is-bytes-content.qf1` compiles the closer `is_bytes` head check:
  after untagging the atom entry, it checks length `5`, the first four bytes
  `"Byte"`, and the final byte `"s"`. The object deliberately uses a distinct
  static atom label so pointer identity is not enough.
- `stage4-is-bytes-content-reject.qf1` uses the same compiled check with a
  `Bytez` atom and exits with status `1`, covering the negative path for the
  final-character comparison.
- `stage4-is-bytes-content-output.qf1` uses content-based `IsBytes` to gate a
  real byte-output path for static `(Bytes 41)`, then emits byte `41`.
- `stage4-is-bytes-content-linear.qf1` compiles the same successful byte-output
  path with explicit scoped local labels and fail-fast `jnz` branches. This
  proves the smaller branch primitive locally, without growing the common
  qfasm3/qfc4 sources.
- `qfc4-byte-output.qf1`, `qfasm-byte-output-ext.qf1`, and
  `stage4-is-bytes-content-linear-direct.qf1` split that focused byte-output
  path into a direct compiler slice, an optional assembler extension, and a
  source-only fixture. The generated ELF is byte-identical to the linear
  fixture and emits byte `41`.
- `qfasm2-exit42-n221.qf1` proves the optional assembler extension can emit a
  221-byte code segment, one byte past the common `N220` file-size range, and
  still produce a runnable ELF.
- `qfasm2-entry-n221.qf1` places the ELF entry label at code offset `N221`,
  proving the optional `Addr N221` path for a runnable ELF.
- `stage5-pair-allocation.qf1` uses optional heap extensions to compile dword
  stores, emits a writable executable segment, writes a pair cell into a static
  heap area, reads the car field back, and exits with status `42`.
- `stage5-bump-alloc.qf1` adds a mutable `HeapNext` cell and performs two pair
  constructions through it. The generated ELF exits with the first cell's car
  (`19`), proving the second allocation used the advanced pointer instead of
  overwriting the first cell.
- `stage5-alloc-proc.qf1` factors that heap bump into a reusable compiled
  `AllocPair` routine. Callers pass car/cdr in `EBX`/`ECX`; the routine writes
  the pair, advances `HeapNext`, returns the pair in `EAX`, and is called twice
  by the checked program.
- `stage5-alloc-checked.qf1` and `stage5-alloc-overflow.qf1` prove the first
  allocator bounds check at the qfasm2 layer. They compare `HeapNext + 8` with
  `HeapLimit` before storing and cover both successful allocation (`19`) and
  overflow (`7`).
- `stage5-alloc-checked-qfc4.qf1` and `stage5-alloc-overflow-qfc4.qf1` lift
  that first bounds-check branch through qfc4. The source now expresses
  `HeapNext + 8 <= HeapLimit` with the qfc4 `IfBelowEq` surface, and the
  generated ELFs cover commit (`19`) and overflow (`7`).
- `stage5-alloc-reset-gc.qf1` proves a minimal no-live-objects recovery policy
  at the qfasm2 layer: overflow resets `HeapNext` to `Heap`, retries, stores a
  pair, and exits with status `19`.
- `stage5-alloc-reset-gc-qfc4.qf1` lifts that no-live-objects recovery through
  qfc4. The staged source now performs the overflow branch, resets `HeapNext`,
  retries allocation, and exits with the recovered pair car (`19`).
- `stage5-copy-root-gc.qf1` extends recovery to one live root at the qfasm2
  layer: overflow copies the root pair into the reset heap, updates the root
  slot, allocates another pair after it, and exits with the copied root car
  (`19`).
- `stage5-copy-root-gc-qfc4.qf1` lifts the root-copy/update mechanics through
  qfc4. It factors the staged source into `CopyRoot` and `AllocAfterCopy`,
  updates `Root`, advances `HeapNext`, allocates after the copied root, and
  exits with the copied car (`19`).
- `stage5-copy-graph-gc.qf1` extends that to one internal pointer: overflow
  copies a root pair and its tail pair, rewrites the copied root's cdr to the
  copied tail, allocates after both copied cells, and exits with the copied tail
  car (`19`). The old tail is reused as the retry allocation cell, so an
  unrevised internal pointer exits `42`.
- `stage5-copy-graph-gc-qfc4.qf1` lifts the same fixed graph-copy shape through
  qfc4. It uses the optional `qfc4-copy-ext.qf1` statement layer to keep the
  staged source small while compiling copy, root update, and retry allocation
  operations through Qfitzah rules.
- `stage5-copy-list-gc.qf1` replaces the fixed two-cell copy with a traversal
  loop over a nil-terminated pair list. It threads a `LinkSlot` through the root
  slot and copied cdr fields, copies three pairs, overwrites the old tail, then
  exits through the copied tail (`19`).
- `stage5-copy-list-gc-qfc4.qf1` lifts that list traversal through qfc4 using
  the optional `qfc4-list-copy-ext.qf1` statement layer. Its test runs qfc4 and
  qfasm as two Qfitzah invocations to keep the seed rule set small, then runs
  the generated ELF and exits through the copied tail (`19`).
- `stage5-copy-nested-pair-gc.qf1` starts replacing list-only traversal with
  object traversal at the qfasm2 layer. It copies a root pair whose `car` is
  another pair, rewrites the copied car edge to the copied child, overwrites
  the old child, and exits through the copied child (`19`).
- `stage5-copy-two-field-object-gc.qf1` extends that proof to both fields of a
  root pair. It copies and rewrites pair-valued `car` and `cdr` children,
  overwrites both old children, verifies the copied `car` child, and exits
  through the copied `cdr` child (`23`).
- `stage5-copy-two-field-object-gc-qfc4.qf1` lifts the two-field object copy
  proof through qfc4. It uses optional object-copy and raw object-data rules,
  runs qfc4 and qfasm as two Qfitzah invocations, and keeps data before code so
  the final assembler stays inside its finite address table.
- `stage5-copy-tree-gc.qf1` starts generalizing fixed object copies into a
  qfasm2-level scan-copy traversal. It walks copied pairs from `Scan` to
  `HeapNext`, copies newly discovered pair-valued `car` and `cdr` fields,
  rewrites those copied fields, and proves the copied tree remains live after
  old leaves are overwritten. This covers acyclic pair trees, not sharing or
  cycles.
- `stage5-copy-tree-gc-qfc4.qf1` lifts that scan-copy traversal through qfc4
  using `qfc4-scan-copy-ext.qf1`. The staged test emits a runnable ELF through
  qfc4 -> qfasm3 -> qfasm2 and exits through the copied right leaf (`35`).
- `stage5-forwarding-gc.qf1` starts sharing preservation at the qfasm2 layer.
  A root has both fields pointing at one old pair; recovery copies that child
  once, stores a temporary forwarding pointer/marker in the old pair, rewrites
  both copied fields to the single new child, checks pointer equality and
  `HeapNext`, and exits through the copied child (`19`). This is a focused
  shared-acyclic-pair proof, not a cycle-safe or fully general forwarding
  representation yet.
- `stage5-forwarding-gc-qfc4.qf1` lifts that focused forwarding proof through
  qfc4. Its first Qfitzah invocation lowers qfc4 source to qfasm3 with
  `qfc4-forwarding-ext.qf1`; its second invocation uses
  `qfasm-stage5-forwarding-ext.qf1` and the Stage 5 heap/scan extensions to
  emit a runnable ELF that exits through the copied child (`19`).
- `stage5-forwarding-cycle-gc.qf1` extends forwarding to a one-pair cycle. The
  old root's `car` points back to the old root; recovery copies the pair once,
  marks the old pair forwarded, rewrites the copied `car` to the copied pair
  itself, overwrites the old pair, and exits through the copied self-cycle
  (`23`). `stage5-forwarding-cycle-gc-qfc4.qf1` lifts the same proof through
  qfc4 using separate cycle-forwarding extension files so it stays inside the
  seed runtime's source budget.
- `stage5-scan-forwarding-gc.qf1` combines the scan-copy traversal and
  forwarding mechanisms at the qfasm2 layer. A copied root has two fields that
  point at one old child, and that child points to itself. The scan loop copies
  the child once, records a forwarding marker, rewrites both root fields and
  the child's self-edge to the copied child, checks `HeapNext`, and exits
  through the copied child car (`19`).
- `stage5-scan-forwarding-complex-gc.qf1` exercises the same qfasm2-level
  scan-forwarding loop on a larger mixed graph. Root has two distinct children,
  both children point at one shared self-cyclic node, and the shared node's car
  is a tagged static atom. Every old pair object is overwritten after recovery,
  and the generated ELF verifies preserved sharing, the copied self-cycle, the
  copied atom field, and the four-cell copy frontier before exiting `19`.
- `stage5-scan-forwarding-complex-gc-qfc4.qf1` lifts that mixed graph through
  qfc4 using a separate complex scan-forwarding extension and a local
  tagged-constant compare assembler extension, preserving the same staged
  two-invocation pipeline while avoiding extra rule load in the smaller qfc4
  scan-forwarding proof.
- `stage5-scan-forwarding-dynamic-atom-gc.qf1` combines forwarding with
  runtime-initialized atom copying at the qfasm2 layer. The copied child has a
  self-cycle rewritten through a forwarding marker, then its cdr atom is copied
  into the separate atom frontier. Old root, child, and atom records are
  overwritten before the generated ELF verifies the copied cycle, frontier
  positions, and copied atom length.
- `stage5-scan-forwarding-dynamic-atom-gc-qfc4.qf1` lifts that combined
  forwarding-plus-runtime-atom proof through qfc4 using
  `qfc4-scan-forwarding-dynamic-atom-ext.qf1`. The staged test uses the split
  short-branch pass-through shim for reused scan snippets and verifies exit
  status `0` after checking the copied cycle, frontiers, and atom length.
- `stage5-scan-forwarding-gc-qfc4.qf1` lifts the same shared cyclic scan graph
  through qfc4 using `qfc4-scan-forwarding-ext.qf1`. The qfc4 source keeps the
  scan loop readable, places one field handler before `Start` to keep calls in
  range, and the generated ELF exits through the copied child car (`19`).
- `stage5-copy-bytes-output-gc.qf1` connects the recovery path to byte output
  at the direct qfasm2 layer. It forces recovery, copies a static `(Bytes 41)`
  object graph, overwrites the old pair objects, then emits from the copied
  byte atom through `EmitByte`, `Nybble`, and `write(2)`. The generated ELF
  writes byte `41` and exits `0`.
- `stage5-copy-bytes-isbytes-output-gc.qf1` adds a content-based `IsBytes`
  gate after recovery at the direct qfasm2 layer. The copied head atom is not a
  shared `AtomBytes` pointer; it is recognized by length and character contents
  before the copied byte tail is emitted as stdout `41`.
- `stage5-copy-nested-bytes-output-gc.qf1` extends the direct recovered-output
  path to `(Bytes (Bytes 41))`. The scan copies the outer list, inner `Bytes`
  object, and inner byte tail, all old pairs are overwritten, and recursive
  `EmitBytes` uses content-based `IsBytes` to flatten the copied nested object
  to stdout `41`.
- `stage5-copy-bytes-isbytes-output-gc-qfc4.qf1` lifts the content-checked
  recovery/output path through qfc4 using
  `qfc4-copy-bytes-isbytes-output-ext.qf1` and `qfasm-byte-output-ext.qf1`.
  The staged test checks the exact generated ELF, runtime stdout `41`, and
  exit status `0`.
- `stage5-copy-nested-bytes-output-gc-qfc4.qf1` lifts the recovered nested
  `EmitBytes` proof through qfc4 using
  `qfc4-copy-nested-bytes-output-ext.qf1` and `qfasm-byte-output-ext.qf1`.
  The staged source keeps recursive `EmitBytes`, content-based `IsBytes`,
  `EmitByte`, and `Nybble` readable while the generated ELF still emits stdout
  `41` after old pairs are overwritten.
- `stage5-copy-dynamic-atoms-output-gc.qf1` starts replacing static atom
  records with runtime-initialized atom cells. The scan still keeps pairs in
  the normal scan frontier, but tagged atom fields in pair cars are copied into
  a separate atom frontier and rewritten to tagged copied atoms. The old atom
  records are overwritten before the copied `Bytes` object is checked by
  content and emitted as stdout `41`.
- `stage5-copy-dynamic-atom-cdr-gc.qf1` extends that direct atom frontier proof
  to tagged atom fields in pair cdrs. The copied cdr is rewritten to the copied
  atom record, the old atom is overwritten, and the generated ELF emits stdout
  `41` from the copied cdr atom.
- `stage5-copy-dynamic-atom-fields-gc.qf1` combines the car and cdr dynamic
  atom paths in one copied pair. Both runtime-initialized atom fields are
  rewritten to copied atom records, all old records are overwritten, and the
  generated ELF emits stdout `41` from the copied cdr atom.
- `stage5-copy-dynamic-atom-fields-gc-qfc4.qf1` lifts that combined
  runtime-initialized atom-copy proof through qfc4. The staged test lowers
  qfc4 to qfasm3, uses a small qfasm3 branch pass-through shim for the direct
  scan snippets, assembles an exact ELF, and verifies stdout `41`.
- `stage5-copy-dynamic-atom-nested-gc-qfc4.qf1` pushes the same atom frontier
  through scan-discovered graph traversal. Recovery copies the root pair, the
  scan loop later copies its child pair, and the child's runtime-initialized
  cdr atom is copied only when that child is scanned. The generated ELF
  overwrites all old records and verifies the copied child cdr points to the
  copied atom record.
- `stage5-copy-dynamic-atom-deep-gc-qfc4.qf1` extends that proof across
  multiple scan iterations. Root, child, and grandchild pairs are copied in
  order, and the grandchild's runtime-initialized cdr atom is copied only after
  traversal reaches the grandchild. The generated ELF verifies the copied pair
  chain and atom field after old records are overwritten.
- `stage5-copy-bytes-output-gc-qfc4.qf1` lifts the same GC-plus-byte-output
  proof through qfc4 using `qfc4-copy-bytes-output-ext.qf1` and the existing
  scan-copy extension. The staged test checks the exact generated ELF, runtime
  stdout `41`, and exit status `0`.

Still required for the byte-output path:

- extending scan-forwarding from focused and mixed pair graphs to arbitrary
  Qfitzah object graphs
- generalizing the pair-tree traversal into arbitrary live Qfitzah objects
- generalizing runtime-initialized atom copying beyond focused field-copy,
  linear scan-discovered child fixtures, and the focused forwarding-plus-atom
  qfc4 proof
- larger object graphs beyond the current finite layout budget
- generalizing the recovered nested `EmitBytes` proof beyond the focused
  `(Bytes (Bytes 41))` fixture without exceeding the seed runtime's current
  source-size budget; see `bootstrap/source-size-budget.md`
- enough data layout notation to express larger Qfitzah object graphs
- integration with evaluated expression output and the normal printer

Only after those pieces exist should the roadmap mark Stage 5 as implemented.

## Reader Progress

The seed reader now supports parenthesized forms spanning physical lines. The
input loop accumulates bytes until parenthesis depth returns to zero, ignores
parentheses inside semicolon comments, terminates the logical record with NUL on
newline or EOF, and lets the parser treat embedded newlines as whitespace.

This improves the bootstrap substrate for readable staged sources, but it is
not yet a fully general stream reader. A traditional two-form rewrite rule is
still a single logical record containing the pattern and replacement, but
readable multi-line rules can now be written as `(Rule pattern replacement)`.
`bootstrap/stage1-multiline-rules.qf1` is the first Qfitzah-improved bootstrap
fixture and tests that behavior directly. `bootstrap/qfasm3.qf1`,
`bootstrap/qfc4.qf1`, and their sample inputs now use that style, so the
macro-assembler and compiler stages depend on the improved reader rather than
merely testing it in isolation.
