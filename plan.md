# Qfitzah Bootstrap Strengthening Roadmap

This document outlines the sequential phases, architectural changes, and actionable tasks required to transition the Qfitzah bootstrap pipeline from a hand-maintained binary emitter to a self-hosting compiler.

---

## Stage 1: Direct ELF S-Expression Generator (Current Baseline)
The initial stage focuses on achieving absolute binary correctness relative to the GCC-compiled seed executable. All code, headers, offsets, and data layouts are maintained directly.

- [x] **Task 1.1: Map Code Layout**
  Document the exact memory boundaries and sizes of the 1340-byte seed executable.
- [x] **Task 1.2: Maintain Hand-Coded Macros**
  Map individual x86 instruction structures to explicit Lisp byte-emission wrappers.
- [x] **Task 1.3: Track Offsets Manually**
  Hand-calculate all relative branch offsets, calls, and segment-offset alignment paddings.
- [x] **Task 1.4: Single-Line Annotation Alignment**
  Document and maintain the exact machine-to-assembly correspondence in a flat, readable layout without raw hex columns.

---

## Stage 2: Symbolic Assembler (The "hex1 / M1" Level)
The primary objective of this stage is to automate PC-relative offset and absolute memory address calculations, removing manual binary-hacking.

- [x] **Task 2.1: Implement a Symbol Table**
  Create a dictionary data structure to map symbolic label names (e.g., `_start:`, `handle_line:`) to their calculated addresses.
- [x] **Task 2.2: Implement Pass 1 (Size Estimation)**
  Parse the S-expression list of instructions, calculate the byte size of each macro wrapper, and assign an absolute virtual address to each label.
- [x] **Task 2.3: Implement Pass 2 (Byte Emission & Offset Resolution)**
  Traverse the list a second time to resolve labels, calculating relative offsets via `target_address - current_instruction_pointer` and absolute global displacements from `%ebp`.
- [x] **Task 2.4: Automate ELF Header Alignment**
  Enable the assembler to dynamically calculate `e_shoff`, `p_filesz`, and segment offsets, adjusting alignment padding blocks automatically as code size changes.
- [x] **Task 2.5: Unify Branch Macros**
  Replace hand-sized jump macros with abstract operations (e.g., `(JUMP label)` and `(CALL label)`) that automatically generate the correct short (8-bit) or near (32-bit) encoding based on distance.

Implemented as `bootstrap/qfasm2.qf1`, a Qfitzah-hosted assembler rule file.
It runs under `qfitzah`, resolves symbolic labels, emits a complete i386 ELF
binary, and is tested with runnable output. The current arithmetic tables cover
the small bootstrap range. Branch lowering currently covers short jumps and
signed direct calls in that range, including backward recursive calls; widening
to fully automatic short-vs-near jump selection remains part of making this
stage general. The current data-layout tables also cover the static tagged
object examples used by the Stage 4 runtime slices.

---

## Stage 3: Macro-Assembler & Structured Code Generator (The "M2" Level)
This stage introduces high-level control abstractions and calling conventions to reduce the complexity of writing raw assembly.

- [x] **Task 3.1: Support Local Label Scopes**
  Add support for scoped or anonymous local labels (e.g., `.1:`, `.2f`) so that nested conditions do not cause symbol collisions.
- [x] **Task 3.2: Implement Structured Flow Macros**
  Create helper macros that expand structured conditions into basic conditional jump sequences:
  ```lisp
  (IF (test-condition)
      (then-instructions)
      (else-instructions))
  ```
- [x] **Task 3.3: Abstract Calling Conventions**
  Implement an `(INVOKE procedure args...)` macro that automatically loads arguments into the target registers or pushes them to the stack, standardizing function invocation.
- [x] **Task 3.4: Automate Register Clobber Preservation**
  Include automatic saving (`push`) and restoring (`pop`) of clobbered registers at function boundaries based on the calling convention.

Implemented as `bootstrap/qfasm3.qf1`, a Qfitzah-hosted macro layer that expands
to qfasm2 data. Its source rules and test program use readable multi-line
forms. The test program uses scoped local labels, an `IfZero` block, `Invoke`,
and `Ecx` clobber preservation, then emits and runs an ELF binary.

---

## Stage 4: Minimal Qfitzah Compiler (The "MesCC" Level)
Build a compiler, written in a subset of Qfitzah, that compiles Qfitzah source S-expressions down into Stage 3 Macro Assembly.

- [x] **Task 4.1: Develop AST Parser**
  Write an S-expression parser that converts high-level expressions into an Abstract Syntax Tree (AST).
- [x] **Task 4.2: Match-Expression Compiler**
  Implement a compilation path that translates high-level, declarative `match` and rewrite rules into native condition trees, removing manual pattern matching code.
- [x] **Task 4.3: Automate Pointer Alignment & Tagging**
  Generate instruction streams that automatically enforce pointer alignment and type tags (e.g., tagging cons cells, constants, and variables) during data generation.
- [x] **Task 4.4: Automate Stack Frame Allocation**
  Generate appropriate function prologues and epilogues to manage stack frames, local variables, and register states dynamically.

Implemented as `bootstrap/qfc4.qf1`, a Qfitzah-hosted compiler slice. It parses
high-level source forms into explicit AST nodes, lowers declarative zero-match
forms into qfasm3 `IfZero` trees, emits tag-setting code for aligned constant
payloads, and turns frame preservation requests into qfasm3 procedure clobber
metadata. The checked examples produce runnable ELF binaries through the full
qfc4 -> qfasm3 -> qfasm2 pipeline.

---

## Stage 5: Self-Hosting Runtime & Full Qfitzah
Develop the full language compiler compiled by the Stage 4 compiler, moving toward full self-hosting and robust execution.

The repository is not self-hosting yet. The current qfc4 compiler slice cannot
express the whole `qfitzah.s` runtime. See
`bootstrap/self-hosting-gap.md` for the concrete missing runtime mechanisms and
the next subsystem-sized milestone.

Current self-hosting progress: `bootstrap/stage4-nybble.qf1` compiles the
`nybble` routine shape from `qfitzah.s` through qfc4 -> qfasm3 -> qfasm2 into a
runnable ELF. This proves calls, static data loads, byte arithmetic, compare,
and conditional branch lowering for one real runtime subsystem. It is not yet
enough for `is_bytes`, Qfitzah object traversal, or the full interpreter.
`bootstrap/stage4-emit-byte.qf1` extends this by compiling an `emit_byte`-shaped
routine that calls `Nybble` twice, combines the nybbles, and writes byte `41`
to stdout from the generated ELF. `bootstrap/stage4-emit-bytes.qf1` adds a
recursive `EmitBytes`-shaped byte-span walker that writes `ABCDE` and requires a
signed backward call displacement. `bootstrap/stage4-emit-bytes-object.qf1`
then moves the same path onto a static tagged `(Bytes 41)` object with aligned
pair cells, tagged atom pointers, nil, field loads, a `Bytes` head check, and
recursive cons-tail traversal. `bootstrap/stage4-emit-bytes-nested.qf1` adds a
focused static-object slice for nested `(Bytes ...)` flattening by compiling
`(Bytes (Bytes 41))` and recursively emitting the nested cdr.
`bootstrap/stage4-emit-bytes-general.qf1` combines cons-tail traversal and
nested `Bytes` flattening in one compiled `EmitBytes` routine using tail-call
jumps for the outer-list loop. `bootstrap/stage4-is-bytes-content.qf1` compiles
the closer `is_bytes` head check, recognizing a static `Bytes` atom by length
and character contents rather than by a shared pointer.
`bootstrap/stage4-is-bytes-content-reject.qf1` covers the negative path with a
same-shaped `Bytez` atom.
`bootstrap/stage4-is-bytes-content-output.qf1` uses the content-based check to
gate real byte output for static `(Bytes 41)`.
`bootstrap/stage4-is-bytes-content-linear.qf1` recompiles that path with
explicit local labels and fail-fast `jnz` branches, proving a smaller
control-flow primitive for runtime predicates without adding it to the common
compiler source.
`bootstrap/qfc4-byte-output.qf1` and `bootstrap/qfasm-byte-output-ext.qf1`
split that focused path into a direct byte-output compiler slice plus an
optional assembler extension. `bootstrap/stage4-is-bytes-content-linear-direct.qf1`
uses the split stages and produces the same byte-output ELF.
`bootstrap/qfasm2-exit42-n221.qf1` proves the optional assembler extension can
emit a 221-byte code segment, one byte past the common `N220` range.
`bootstrap/qfasm2-entry-n221.qf1` then proves an ELF entry label at offset
`N221`, covering optional address emission as well as file size.
`bootstrap/stage5-pair-allocation.qf1` starts the mutable-runtime work needed
before GC can be meaningful: it compiles dword stores through optional heap
extensions, writes a pair cell into a static heap area, reads the car field
back, and exits with status `42`.
`bootstrap/stage5-bump-alloc.qf1` adds a checked heap-next update: it allocates
two pair cells through a mutable `HeapNext` pointer and exits with the first
cell's car (`19`), proving the second allocation used the advanced pointer
rather than overwriting the first cell.
`bootstrap/stage5-alloc-proc.qf1` then factors the same logic into a reusable
compiled `AllocPair` procedure that accepts car/cdr in `EBX`/`ECX`, advances
`HeapNext`, returns the allocated pair in `EAX`, and is called twice by the
checked program.
`bootstrap/stage5-alloc-checked.qf1` and
`bootstrap/stage5-alloc-overflow.qf1` add a lower-level qfasm2 bounds-check
proof: compare `HeapNext + 8` with `HeapLimit` before storing, exercise both
the success path (`19`) and overflow path (`7`).
`bootstrap/stage5-alloc-checked-qfc4.qf1` and
`bootstrap/stage5-alloc-overflow-qfc4.qf1` lift that first bounds-check branch
back through qfc4, proving the staged compiler surface can now express the
checked commit and overflow paths.
`bootstrap/stage5-alloc-reset-gc.qf1` adds the first lower-level recovery
policy: the overflow path resets `HeapNext` to the heap base, retries the
allocation, stores one pair, and exits `19`. This is a no-live-objects GC proof,
not a tracing collector yet.
`bootstrap/stage5-alloc-reset-gc-qfc4.qf1` lifts that no-live-objects recovery
through qfc4, so the staged compiler surface now expresses reset, retry,
commit, and recovered allocation output.
`bootstrap/stage5-copy-root-gc.qf1` then preserves one live root across that
recovery: it copies the root pair into the reset heap, updates the root slot,
allocates another pair after it, and exits with the copied root car (`19`).
`bootstrap/stage5-copy-root-gc-qfc4.qf1` lifts the same root-copy/update
mechanics through qfc4, factoring the staged source into `CopyRoot` and
`AllocAfterCopy` procedures so larger recovery logic can be expressed without a
single deeply nested compiler input.
`bootstrap/stage5-copy-graph-gc.qf1` extends that qfasm2-level recovery proof
to a two-pair graph: the copied root's cdr is rewritten to the copied tail,
allocation resumes after both copied cells, and the ELF exits with the copied
tail car (`19`). The fixture now reuses the old tail as the retry allocation
cell, so a missed cdr rewrite exits `42`.
`bootstrap/stage5-copy-graph-gc-qfc4.qf1` lifts the same fixed graph-copy shape
through qfc4 using the optional `bootstrap/qfc4-copy-ext.qf1` statement layer.
That keeps the staged source below the seed runtime's practical rule budget
while still lowering the copy operations through Qfitzah rules.
`bootstrap/stage5-copy-list-gc.qf1` replaces the fixed two-cell shape with a
loop over a nil-terminated list. It threads a `LinkSlot` through the root slot
and copied cdr fields, copies three pairs until nil, then proves old internal
pointers are gone by overwriting the old tail before reading the copied tail.
`bootstrap/stage5-copy-list-gc-qfc4.qf1` and
`bootstrap/qfc4-list-copy-ext.qf1` lift that loop shape through qfc4. The test
uses a two-invocation Qfitzah pipeline, first lowering qfc4 to qfasm3 source
and then assembling that source to a runnable ELF, because the all-in-one
optional rule load still exceeds the seed runtime's stable budget.
`bootstrap/stage5-copy-nested-pair-gc.qf1` starts replacing the list-only
traversal proof with object traversal: it follows a pair-valued `car` edge,
copies that child, rewrites the copied root's car to the copied child, then
overwrites the old child so stale internal edges are observable.
`bootstrap/stage5-copy-two-field-object-gc.qf1` extends that object proof to a
root whose `car` and `cdr` are both pair-valued edges. Recovery copies and
rewrites both fields, overwrites both old children, checks the copied `car`
child, then exits through the copied `cdr` child (`23`).
`bootstrap/stage5-copy-two-field-object-gc-qfc4.qf1` lifts the same two-field
object shape through qfc4 with optional object-copy and raw object-data
extensions. Its test keeps qfc4 and qfasm as two Qfitzah invocations and places
data before code so the assembler's finite address facts stay in range.
`bootstrap/stage5-copy-tree-gc.qf1` then replaces the fixed object shape with a
qfasm2-level scan over copied pairs. The recovery path keeps a `Scan` cursor and
`HeapNext`, discovers pair-valued `car` and `cdr` fields during traversal,
copies those children, rewrites the copied fields, and exits through a copied
nested right leaf (`35`). This proves acyclic pair-tree traversal, while sharing
and cycles remain future forwarding-pointer work.
`bootstrap/stage5-copy-tree-gc-qfc4.qf1` and
`bootstrap/qfc4-scan-copy-ext.qf1` lift that scan-copy traversal through qfc4.
The staged test runs qfc4 and qfasm separately, uses the local scan qfasm
extension for the near loop backedge, and exits through the copied right leaf
(`35`).
`bootstrap/stage5-forwarding-gc.qf1` starts the forwarding-pointer path at the
qfasm2 layer. A root whose two fields share one old pair copies that child once,
marks the old child with a temporary forwarding marker, rewrites both copied
fields to the same new child, checks pointer equality and `HeapNext`, and exits
through the copied child (`19`).
`bootstrap/stage5-forwarding-gc-qfc4.qf1` lifts that focused sharing proof
through qfc4 with `bootstrap/qfc4-forwarding-ext.qf1` and
`bootstrap/qfasm-stage5-forwarding-ext.qf1`, again producing a runnable ELF that
exits through the copied child (`19`).
`bootstrap/stage5-forwarding-cycle-gc.qf1` extends the same mechanism to a
one-pair cycle: the copied root's `car` is rewritten from the old root to the
copied root itself, the old object is overwritten, and the ELF exits through
the copied cycle (`23`). `bootstrap/stage5-forwarding-cycle-gc-qfc4.qf1` lifts
that cycle proof through qfc4 with separate cycle-forwarding extensions to stay
within the seed runtime's source budget.
`bootstrap/stage5-scan-forwarding-gc.qf1` then combines scan traversal with
forwarding at the qfasm2 layer. The scan copies a shared cyclic child once,
rewrites both root fields and the child's self-edge to the copied child, checks
that allocation advanced by only two cells, and exits through the copied child
(`19`). This is the first focused proof that the scan loop and forwarding
marker can cooperate on a cyclic shared graph.
`bootstrap/source-size-budget.md` records the current seed-runtime source-size
boundary that prevents merging content-based `is_bytes` into the full compiled
`EmitBytes` fixture before the common stages are shrunk or split.

Reader progress: the seed runtime now accumulates parenthesized forms across
physical lines and treats embedded newlines as whitespace, which makes staged
rules and programs more readable. Balanced final records are handled at EOF as
well as at newline boundaries. Rules can be written either as the traditional
two-form logical record or as an explicit multi-line `(Rule pattern replacement)`
directive. `bootstrap/stage1-multiline-rules.qf1` is the first
Qfitzah-improved bootstrap fixture and tests that readable rule form directly.
The Stage 3 macro assembler, the Stage 4 compiler source, and their sample
inputs now use that readable multi-line style.

- [ ] **Task 5.1: Implement Garbage Collection (GC)**
  Implement a basic allocator and garbage collector (such as a stop-and-copy or mark-and-sweep collector) to replace the non-reclaimed arena allocator.
- [ ] **Task 5.2: Compile Multiple Dispatch Tables**
  Implement compilation of dynamic multiple-dispatch method tables, mapping method signatures to concrete runtime addresses.
- [ ] **Task 5.3: Add Basic Optimization Passes**
  Integrate optimization passes in the compiler, including tail-call optimization (TCO), constant folding, and dead-code elimination.
- [ ] **Task 5.4: Execute Reproducibility Verification**
  Compile the Stage 5 compiler using the Stage 4 compiler, and then compile the Stage 5 compiler with itself to verify binary identity (reproducibility).
