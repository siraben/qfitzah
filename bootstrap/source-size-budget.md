# Source Size Budget

The current seed runtime can compile the staged runtime slices only while the
concatenated qfasm2 + qfasm3 + qfc4 + fixture source stays below a practical
source-size limit. This is a seed-runtime limit, not a target-machine-code
limit: adding rules to the common stages increases the input that the seed must
intern and rewrite before it can emit an ELF.

## Observed Boundary

These checked fixtures fit:

- `stage4-emit-bytes-general.qf1`
  - one compiled `EmitBytes` routine
  - cons-tail traversal
  - nested `(Bytes ...)` flattening
  - pointer-identity `IsBytes`
- `stage4-is-bytes-content.qf1`
  - content-based `IsBytes`
  - positive path only
  - local comparison rules
- `stage4-is-bytes-content-reject.qf1`
  - content-based `IsBytes`
  - negative final-character path
  - local comparison rules
- `stage4-is-bytes-content-output.qf1`
  - content-based `IsBytes`
  - gates a real byte-output path
  - emits static `(Bytes 41)` as byte `41`
- `stage4-is-bytes-content-linear.qf1`
  - content-based `IsBytes`
  - gates the same byte-output path
  - uses fixture-local scoped labels and fail-fast `jnz` branches
  - emits static `(Bytes 41)` as byte `41`
- `stage4-is-bytes-content-linear-direct.qf1`
  - content-based `IsBytes`
  - uses `qfc4-byte-output.qf1` and `qfasm-byte-output-ext.qf1`
  - keeps qfc4-local rules out of the fixture source
  - emits a byte-identical ELF and static `(Bytes 41)` as byte `41`
- `qfasm2-exit42-n221.qf1`
  - uses `qfasm-n221-ext.qf1`
  - assembles a 221-byte code segment, one byte past qfasm2's common `N220`
    file-size range
  - emits a runnable ELF that exits with status `42`
- `qfasm2-entry-n221.qf1`
  - uses `qfasm-n221-ext.qf1`
  - places the ELF entry label at code offset `N221`
  - checks optional `Addr N221`, `FileSize N233`, and arithmetic through the
    following 12-byte exit sequence
- `stage5-pair-allocation.qf1`
  - uses `qfasm-heap-ext.qf1` and `qfc4-heap-ext.qf1`
  - emits a writable executable segment for a focused mutable-data proof
  - stores car/cdr dwords into a static heap cell, reads the car back, and exits
    with status `42`
- `stage5-bump-alloc.qf1`
  - reuses the optional heap extensions
  - stores and reloads a mutable `HeapNext` cell
  - constructs two pair cells and exits with the first car (`19`) to prove the
    second allocation used the advanced pointer
- `stage5-alloc-proc.qf1`
  - factors the heap-next update into a reusable compiled `AllocPair` procedure
  - calls the procedure twice, returning allocated pairs in `EAX`
  - exits with the first pair's car (`19`) to prove separate allocations
- `stage5-alloc-checked.qf1` and `stage5-alloc-overflow.qf1`
  - use `qfasm-heap-check-ext.qf1`
  - prove the first allocator bounds check at the qfasm2 layer
  - cover success (`19`) and overflow (`7`) as the direct lower-level baseline
- `stage5-alloc-checked-qfc4.qf1` and `stage5-alloc-overflow-qfc4.qf1`
  - use `qfasm-heap-check-ext.qf1` through the qfc4 -> qfasm3 -> qfasm2 path
  - prove qfc4 can express the first checked allocator branch
  - cover successful commit (`19`) and overflow (`7`)
- `stage5-alloc-reset-gc.qf1`
  - uses the same qfasm2 heap-check extension
  - resets `HeapNext` to `Heap` on overflow and retries allocation
  - proves a no-live-objects recovery policy with runtime status `19`
- `stage5-alloc-reset-gc-qfc4.qf1`
  - uses the qfc4 -> qfasm3 -> qfasm2 path with the heap-check extension
  - lifts reset/retry recovery into staged source
  - exits with the recovered pair car (`19`)
- `stage5-copy-root-gc.qf1`
  - copies one live root pair into the reset heap
  - updates the root slot, retries allocation after the copied root, and exits
    with the copied root car (`19`)
- `stage5-copy-root-gc-qfc4.qf1`
  - uses the qfc4 -> qfasm3 -> qfasm2 heap path
  - loads optional `qfc4-raw-data-ext.qf1` for raw pair data layout
  - copies and updates one root through staged `CopyRoot` and `AllocAfterCopy`
    procedures, then exits with the copied root car (`19`)
- `stage5-copy-graph-gc.qf1`
  - uses the same qfasm2 heap-check extension, plus size facts through `N225`
  - copies a root pair and its tail pair, rewrites the copied root's cdr to the
    copied tail, resumes allocation after both copied cells, and exits with the
    copied tail car (`19`)
  - reuses the old tail as the retry allocation cell, so a stale internal
    pointer would exit `42`
- `stage5-copy-graph-gc-qfc4.qf1`
  - uses `qfc4-copy-ext.qf1` with the plain qfc4 heap path
  - compacts repeated copy/update instruction sequences into optional qfc4
    statement rules; loading the heap-check extension in the same combination
    still exceeds the seed runtime's stable budget
  - proves the fixed two-cell graph-copy shape through qfc4 and exits with the
    copied tail car (`19`)
- `stage5-copy-list-gc.qf1`
  - uses `qfasm-stage5-list-ext.qf1` to keep the larger traversal range local
  - traverses a nil-terminated pair list with a `LinkSlot` update cell
  - copies three pairs, overwrites the old tail, allocates after the copied
    list, and exits with the copied tail car (`19`)
- `stage5-copy-list-gc-qfc4.qf1`
  - uses `qfc4-list-copy-ext.qf1` for qfc4-level loop statements and
    `qfasm-stage5-list-ext.qf1` for the final assembly range
  - runs as a staged qfc4 -> qfasm3 source, then qfasm3/qfasm2 -> ELF pipeline
    under Qfitzah; loading all of those optional rules at once still exceeds
    the seed runtime's stable budget
  - copies the same three-pair list, overwrites the old tail, allocates after
    the copied list, and exits with the copied tail car (`19`)
- `stage5-copy-nested-pair-gc.qf1`
  - uses the qfasm2 heap/check/list extension stack
  - follows and rewrites a pair-valued `car` edge, proving the recovery path is
    no longer restricted to cdr-only list traversal
  - overwrites the old child and allocates after the copied graph, exiting with
    the copied child car (`19`)
- `stage5-copy-two-field-object-gc.qf1`
  - uses the same qfasm2 heap/check/list extension stack
  - follows and rewrites pair-valued `car` and `cdr` edges from one root object
  - overwrites both old children, verifies the copied `car` child, and exits
    with the copied `cdr` child car (`23`)
- `stage5-copy-two-field-object-gc-qfc4.qf1`
  - uses `qfc4-copy-ext.qf1`, `qfc4-object-copy-ext.qf1`, and
    `qfc4-object-data-ext.qf1` for qfc4-level object-copy statements and raw
    object layout
  - runs as a staged qfc4 -> qfasm3 source, then qfasm3/qfasm2 -> ELF pipeline
    under Qfitzah, with `qfasm-stage5-list-ext.qf1` supplying the local range
    facts needed by the final assembly
  - keeps data before code so labels used by `Mov*Label` and `DwordLabel`
    remain in the assembler's finite address table
  - copies and rewrites both pair-valued fields and exits with the copied `cdr`
    child car (`23`)
- `stage5-copy-tree-gc.qf1`
  - generated by `tools/generate_stage5_copy_tree_gc.py` to keep the direct
    qfasm2 nesting maintainable
  - uses `qfasm-stage5-scan-ext.qf1` for a register-register comparison and a
    local near conditional branch, because the scan loop no longer fits in one
    short-branch body
  - scans copied pairs from `Scan` to `HeapNext`, copies pair-valued `car` and
    `cdr` children discovered during traversal, rewrites the copied fields, and
    exits through a copied nested right leaf (`35`)
  - proves acyclic pair-tree traversal; forwarding shared or cyclic structures
    is still outside this fixture
- `stage5-copy-tree-gc-qfc4.qf1`
  - uses `qfc4-scan-copy-ext.qf1` plus mixed raw object data forms from
    `qfc4-object-data-ext.qf1`
  - runs as a staged qfc4 -> qfasm3 source, then qfasm3/qfasm2 -> ELF pipeline
    under Qfitzah
  - uses the same `qfasm-stage5-scan-ext.qf1` range and near-branch support as
    the direct scan fixture
  - exits through the copied right leaf (`35`), proving the scan-copy traversal
    now lowers through qfc4
- `stage5-forwarding-gc.qf1`
  - generated by `tools/generate_stage5_forwarding_gc.py` to keep the direct
    qfasm2 nesting maintainable
  - uses the same qfasm2 heap/check/scan extension stack, including
    `CmpEaxEbx`, for pointer-equality checks
  - copies one shared child once, records a temporary forwarding pointer and
    marker in the old child, rewrites both copied root fields to the same new
    child, and exits with the copied child car (`19`)
  - proves a focused shared acyclic pair; cycles and a general forwarding tag
    remain outside this direct fixture
- `stage5-forwarding-gc-qfc4.qf1`
  - generated with `tools/generate_stage5_forwarding_qfc4.py` together with
    `qfc4-forwarding-ext.qf1` and `qfasm-stage5-forwarding-ext.qf1`
  - runs as a staged qfc4 -> qfasm3 source, then qfasm3/qfasm2 -> ELF pipeline
    under Qfitzah
  - exits through the copied shared child (`19`), proving the focused
    forwarding-pointer shape now lowers through qfc4
- `stage5-forwarding-cycle-gc.qf1`
  - generated by `tools/generate_stage5_cycle_forwarding_gc.py`
  - copies a self-referential pair once, resolves the copied self-edge through
    the old object's forwarding marker, overwrites the old object, and exits
    through the copied self-cycle (`23`)
- `stage5-forwarding-cycle-gc-qfc4.qf1`
  - generated with `tools/generate_stage5_cycle_forwarding_qfc4.py` together
    with `qfc4-cycle-forwarding-ext.qf1` and
    `qfasm-stage5-cycle-forwarding-ext.qf1`
  - uses separate optional cycle-forwarding extension files because combining
    the sharing and cycle qfasm expansions in one invocation exceeds the seed
    runtime's stable source budget
  - exits through the copied self-cycle (`23`), proving the cycle-forwarding
    shape now lowers through qfc4
- `stage5-scan-forwarding-gc.qf1`
  - generated by `tools/generate_stage5_scan_forwarding_gc.py`
  - loads `qfasm-stage5-wide-branch-ext.qf1` for `JumpNear` and positive byte
    facts needed by larger forward direct-call/jump offsets
  - keeps those wide branch facts separate from `qfasm-stage5-scan-ext.qf1`
    because the combined extension makes existing staged qfc4 forwarding tests
    exceed the seed runtime's stable source budget
  - factors the scan loop's car/cdr field handling into qfasm2 procedures so
    the loop backedge remains in the stable near-branch range
  - copies a shared cyclic child once, rewrites both root fields and the
    copied child's self-edge to the copied child, verifies `HeapNext`, and exits
    through the copied child car (`19`)
- `stage5-scan-forwarding-complex-gc.qf1`
  - generated by `tools/generate_stage5_scan_forwarding_complex_gc.py`
  - reuses the same direct scan-forwarding field handlers and wide-branch
    extension
  - copies a mixed graph where two distinct child objects converge on one
    shared self-cyclic node whose car is a tagged static atom
  - overwrites every old object, verifies the copied sharing edge, the copied
    self-cycle, the preserved atom field, and the four-cell `HeapNext`
    frontier, then exits `19`
- `stage5-scan-forwarding-complex-gc-qfc4.qf1`
  - generated with `tools/generate_stage5_scan_forwarding_complex_qfc4.py` and
    `qfc4-scan-forwarding-complex-ext.qf1`
  - uses `qfasm-const-compare-ext.qf1` for the local tagged-atom identity check
  - uses a separate qfc4 extension so the larger mixed-graph checks do not add
    rules to the simpler scan-forwarding qfc4 test
  - runs through the staged qfc4 -> qfasm3 source, then qfasm3/qfasm2 -> ELF
    pipeline and exits `19`
- `stage5-scan-forwarding-dynamic-atom-gc.qf1`
  - generated by `tools/generate_stage5_scan_forwarding_dynamic_atom_gc.py`
  - combines forwarding and runtime atom copying at the direct qfasm2 layer
  - copies a self-cyclic child with the forwarding marker, copies that child's
    runtime-initialized cdr atom into the atom frontier, overwrites all old
    records, and verifies the copied cycle plus copied atom length
  - inlines the focused scan handlers to avoid a large forward helper jump
    beyond the current qfasm2 rel32 range
- `stage5-scan-forwarding-dynamic-atom-gc-qfc4.qf1`
  - generated by `tools/generate_stage5_scan_forwarding_dynamic_atom_qfc4.py`
    with `qfc4-scan-forwarding-dynamic-atom-ext.qf1`
  - lowers the combined forwarding-plus-runtime-atom proof through qfc4 while
    keeping the scan loop in staged source
  - uses `qfasm-stage5-branch-ext.qf1` for the raw short branches reused from
    the direct focused field handlers
  - verifies exit status `0` through the staged qfc4 -> qfasm3 source, then
    qfasm3/qfasm2 -> ELF pipeline
- `stage5-copy-bytes-output-gc.qf1`
  - generated by `tools/generate_stage5_copy_bytes_output_gc.py`
  - forces recovery, copies a static `(Bytes 41)` object graph with the direct
    scan-copy traversal, overwrites the old pair objects, then emits from the
    copied byte atom
  - runs the copied atom through the same `EmitByte`/`Nybble`/`write(2)` shape
    used by the Stage 4 byte-output fixtures and verifies runtime stdout `41`
    with exit status `0`
- `stage5-copy-bytes-isbytes-output-gc.qf1`
  - generated by `tools/generate_stage5_copy_bytes_isbytes_output_gc.py`
  - uses `qfasm-byte-output-ext.qf1` for content-comparison instructions
  - copies the same `(Bytes 41)` graph through recovery, overwrites the old
    pairs, then recognizes the copied head atom by length and bytes `"Bytes"`
    before emitting from the copied tail
  - verifies runtime stdout `41` and exit status `0`
- `stage5-copy-nested-bytes-output-gc.qf1`
  - generated by `tools/generate_stage5_copy_nested_bytes_output_gc.py`
  - uses `qfasm-byte-output-ext.qf1` for content-comparison instructions
  - copies a static `(Bytes (Bytes 41))` graph through recovery, overwrites all
    four old pair cells, then recursive `EmitBytes` recognizes both copied
    `Bytes` objects by content and emits from the nested copied tail
  - verifies runtime stdout `41` and exit status `0`
- `stage5-copy-nested-bytes-output-gc-qfc4.qf1`
  - generated by `tools/generate_stage5_copy_nested_bytes_output_qfc4.py`
    with `qfc4-copy-nested-bytes-output-ext.qf1`
  - keeps recursive `EmitBytes`, content-based `IsBytes`, `EmitByte`, and
    `Nybble` in readable qfc4 source
  - reuses `qfc4-scan-copy-ext.qf1` for the recovery scan loop and
    `qfasm-byte-output-ext.qf1` for content-comparison instructions
  - verifies runtime stdout `41` and exit status `0` through the staged qfc4 ->
    qfasm3 source, then qfasm3/qfasm2 -> ELF pipeline
- `stage5-copy-dynamic-atoms-output-gc.qf1`
  - generated by `tools/generate_stage5_copy_dynamic_atoms_output_gc.py`
  - initializes `Bytes` and `41` atom records in writable cells at runtime
    instead of relying on prebuilt static atom records
  - extends the direct scan-copy proof with a separate atom frontier for tagged
    atom fields in pair cars, while keeping the pair scan frontier free of atom
    records
  - overwrites the old atom records before content-checking the copied `Bytes`
    atom and emitting stdout `41`
- `stage5-copy-dynamic-atom-cdr-gc.qf1`
  - generated by `tools/generate_stage5_copy_dynamic_atom_cdr_gc.py`
  - extends the separate atom frontier to a runtime-initialized atom held in a
    pair cdr field
  - checks the copied cdr was rewritten to the copied atom record, overwrites
    the old atom, and emits stdout `41` from the copied cdr atom
- `stage5-copy-dynamic-atom-fields-gc.qf1`
  - generated by `tools/generate_stage5_copy_dynamic_atom_fields_gc.py`
  - combines runtime-initialized atoms in both fields of one copied pair
  - checks both copied fields were rewritten to copied atom records, overwrites
    the old pair and old atom records, and emits stdout `41` from the copied
    cdr atom
- `stage5-copy-dynamic-atom-fields-gc-qfc4.qf1`
  - generated by `tools/generate_stage5_copy_dynamic_atom_fields_qfc4.py` with
    `qfc4-copy-dynamic-atom-fields-ext.qf1`
  - lowers the combined runtime atom field-copy proof through qfc4, then uses
    `qfasm-stage5-branch-ext.qf1` to pass raw short branches from reused scan
    snippets through qfasm3
  - verifies runtime stdout `41` and exit status `0` through the staged qfc4 ->
    qfasm3 -> qfasm2 pipeline
- `stage5-copy-dynamic-atom-nested-gc-qfc4.qf1`
  - generated by `tools/generate_stage5_copy_dynamic_atom_nested_qfc4.py` with
    `qfc4-copy-dynamic-atom-nested-ext.qf1`
  - proves a runtime-initialized cdr atom in a scan-discovered child pair is
    copied only after the child pair itself has been copied by traversal
  - uses the normal pair/nil `ScanCarField` plus a dynamic cdr scanner so the
    loop backedge stays inside the current finite branch range
  - verifies exit status `0` through the staged qfc4 -> qfasm3 -> qfasm2
    pipeline after all old records are overwritten
- `stage5-copy-dynamic-atom-deep-gc-qfc4.qf1`
  - generated by `tools/generate_stage5_copy_dynamic_atom_deep_qfc4.py` with
    `qfc4-copy-dynamic-atom-deep-ext.qf1`
  - extends runtime atom copying across root, child, and grandchild pair copies
    discovered by successive scan iterations
  - keeps byte output out of the fixture and uses the normal `ScanCarField`
    plus dynamic cdr scanner so the qfasm pass stays under the current seed
    source-size and branch-range limits
  - verifies exit status `0` through the staged qfc4 -> qfasm3 -> qfasm2
    pipeline after all old records are overwritten
- `stage5-copy-bytes-isbytes-output-gc-qfc4.qf1`
  - generated by `tools/generate_stage5_copy_bytes_isbytes_output_qfc4.py`
    with `qfc4-copy-bytes-isbytes-output-ext.qf1`
  - keeps the content-based `IsBytes`, `EmitByte`, and `Nybble` routines in
    readable qfc4 source
  - assembles with `qfasm-byte-output-ext.qf1` for the content-comparison and
    fail-fast branch instructions
  - verifies runtime stdout `41` and exit status `0` through the staged qfc4 ->
    qfasm3 source, then qfasm3/qfasm2 -> ELF pipeline
- `stage5-copy-bytes-output-gc-qfc4.qf1`
  - generated by `tools/generate_stage5_copy_bytes_output_qfc4.py` with
    `qfc4-copy-bytes-output-ext.qf1`
  - reuses `qfc4-scan-copy-ext.qf1` for the scan loop and keeps
    `EmitByte`/`Nybble` in readable qfc4 source
  - orders `Start` before `EmitByte` and `Nybble`, so the current finite call
    facts only need the short forward helper calls used by the direct fixture
  - verifies runtime stdout `41` and exit status `0` through the staged qfc4 ->
    qfasm3 source, then qfasm3/qfasm2 -> ELF pipeline
- `stage5-scan-forwarding-gc-qfc4.qf1`
  - generated with `tools/generate_stage5_scan_forwarding_qfc4.py` and
    `qfc4-scan-forwarding-ext.qf1`
  - runs as a staged qfc4 -> qfasm3 source, then qfasm3/qfasm2 -> ELF pipeline
    under Qfitzah
  - keeps one field handler as a helper procedure before `Start` and inlines
    the other in the scan loop so calls and the loop backedge stay inside the
    current finite branch facts
  - exits through the copied child car (`19`), proving the scan-forwarding
    shape now lowers through qfc4

These broader integrations remain unmerged until the common source is smaller
or the combination is re-tested:

- wiring the recovered nested `EmitBytes` path into evaluated expression output
  and the normal printer instead of a focused static fixture
- putting the content-comparison instructions into the common qfasm2/qfasm3/qfc4
  stages instead of keeping them local to a focused fixture

## Next Engineering Step

Before merging recovered byte output into the normal evaluator/printer path,
reduce the always-loaded source:

- continue splitting optional qfasm2/qfasm3/qfc4 extensions into per-fixture
  files; the focused nested content-output path now has a checked split
- continue replacing explicit finite layout tables with generated arithmetic or
  smaller range-specific local tables
- extend the code-size range beyond the checked `N221` proof to real label,
  branch, and data addresses without overflowing the seed's atom/rule budget

Only after that should the byte-output milestone try to combine the focused
runtime slice with:

```text
evaluated expressions + arbitrary object graphs + normal printer output
```
