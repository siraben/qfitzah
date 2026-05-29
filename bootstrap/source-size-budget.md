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
    shared self-cyclic node
  - overwrites every old object, verifies the copied sharing edge, the copied
    self-cycle, and the four-cell `HeapNext` frontier, then exits through the
    copied shared car (`19`)
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

These larger combinations have failed in previous attempts and remain unmerged
until the common source is smaller or the combination is re-tested:

- general `EmitBytes` plus content-based `IsBytes`, including a retry with the
  direct byte-output compiler slice
- putting the content-comparison instructions into the common qfasm2/qfasm3/qfc4
  stages instead of keeping them local to a focused fixture

## Next Engineering Step

Before merging content-based `IsBytes` into the general compiled `EmitBytes`
fixture, reduce the always-loaded source:

- continue splitting optional qfasm2/qfasm3/qfc4 extensions into per-fixture
  files; the focused content-output path now has a checked split
- continue replacing explicit finite layout tables with generated arithmetic or
  smaller range-specific local tables
- extend the code-size range beyond the checked `N221` proof to real label,
  branch, and data addresses without overflowing the seed's atom/rule budget

Only after that should the byte-output milestone try to combine:

```text
content-based is_bytes + arbitrary cons-tail traversal + nested Bytes flattening
```
