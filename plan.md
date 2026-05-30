# Qfitzah Bootstrap Roadmap

This roadmap tracks the bootstrap path from the hand-written seed runtime to a
self-hosted Qfitzah toolchain. It is intentionally a roadmap, not a fixture
ledger. Detailed proof notes live in:

- [bootstrap/self-hosting-gap.md](bootstrap/self-hosting-gap.md)
- [bootstrap/source-size-budget.md](bootstrap/source-size-budget.md)
- [README.md](README.md)

## Current Goal

Qfitzah is not self-hosting yet. The current goal is to turn the Stage 5
subsystem proofs into one compiled runtime/compiler that can rebuild itself
reproducibly. The main blockers are:

- a general collector over arbitrary live Qfitzah objects
- fewer source-budget overlays or a later stage that can generate/load them
- a complete compiled runtime source, not only focused runtime slices
- byte-identical self-rebuild verification

## Stage Shape

The intended architecture has a small number of real stages:

```text
qfitzah.s seed runtime
  -> qfasm2.qf1   symbolic i386 ELF assembler
  -> qfasm3.qf1   macro assembler
  -> qfc4.qf1     small compiler slice
  -> Stage 5      compiled runtime/compiler
```

Files named `*-ext.qf1` are local overlays. They are not independent stages.
They exist because the seed runtime still has finite arithmetic/address tables
and practical source-size limits. The long-term direction is to shrink, merge,
or generate these overlays from a later compiled stage.

## Stage 1: Annotated Seed Runtime

Stage 1 keeps the trusted runtime readable and byte-auditable.

- [x] **Task 1.1: Map Code Layout**
  Document the exact memory boundaries and sizes of the seed executable.
- [x] **Task 1.2: Maintain Hand-Coded Macros**
  Map individual x86 instruction structures to explicit byte-emission forms.
- [x] **Task 1.3: Track Offsets Manually**
  Hand-calculate relative branches, calls, and segment alignment while the seed
  is still trusted assembly.
- [x] **Task 1.4: Single-Line Annotation Alignment**
  Maintain a readable instruction-by-instruction source layout for the seed.

## Stage 2: Symbolic Assembler

Implemented as [bootstrap/qfasm2.qf1](bootstrap/qfasm2.qf1). It runs under the
seed runtime, resolves labels, emits selected i386 instructions, and writes a
complete static ELF.

- [x] **Task 2.1: Implement a Symbol Table**
  Map symbolic labels to calculated addresses.
- [x] **Task 2.2: Implement Pass 1**
  Estimate instruction sizes and assign label addresses.
- [x] **Task 2.3: Implement Pass 2**
  Resolve labels and emit bytes.
- [x] **Task 2.4: Automate ELF Header Alignment**
  Calculate selected ELF sizes, entry addresses, and padding.
- [x] **Task 2.5: Unify Branch Macros**
  Provide symbolic branch/call forms in the bootstrap range.

Remaining generality gap: qfasm2 still relies on finite numeric facts and local
range extensions for larger generated programs.

## Stage 3: Macro Assembler

Implemented as [bootstrap/qfasm3.qf1](bootstrap/qfasm3.qf1). It expands
structured macro assembly into qfasm2 forms.

- [x] **Task 3.1: Support Local Label Scopes**
  Allow generated code to use scoped labels without collisions.
- [x] **Task 3.2: Implement Structured Flow Macros**
  Lower simple conditionals to branch sequences.
- [x] **Task 3.3: Abstract Calling Conventions**
  Provide procedure invocation forms.
- [x] **Task 3.4: Automate Register Clobber Preservation**
  Preserve selected registers through procedure metadata.

## Stage 4: Compiler Slice

Implemented as [bootstrap/qfc4.qf1](bootstrap/qfc4.qf1). It compiles a focused
source language to qfasm3, then qfasm3/qfasm2 produce a runnable ELF.

- [x] **Task 4.1: Develop AST Parser**
  Convert source forms into explicit AST nodes.
- [x] **Task 4.2: Match-Expression Compiler**
  Lower focused declarative matches to native condition trees.
- [x] **Task 4.3: Automate Pointer Alignment and Tagging**
  Generate aligned static data and tagged object pointers.
- [x] **Task 4.4: Automate Stack Frame Allocation**
  Lower frame/clobber metadata to qfasm3 procedure forms.

The compiler slice now covers literals, simple frames, static data, tagged
constants, field loads/stores through extensions, byte output, normal printing,
multiple dispatch proofs, and optimizer proofs. It does not yet express the
whole seed interpreter.

## Stage 5: Runtime and Self-Hosting

Stage 5 is the active work. It is currently a set of checked subsystem proofs,
not a complete runtime. The useful way to read the current Stage 5 work is by
capability area:

- **Reader**: multi-line parenthesized records, comments, EOF-balanced records,
  and explicit `(Rule pattern replacement)` forms are implemented in the seed.
- **Byte output**: staged code can compile byte emission and focused
  `(Bytes ...)` flattening paths.
- **Allocation and GC path**: tests cover checked pair allocation, overflow
  recovery, root copying, list/tree/object copying, forwarding for sharing and
  cycles, scan-forwarding, multi-root forwarding, runtime atom copying, and
  recovered byte/normal output. This is still a family of focused proofs.
- **Normal printer**: qfc4 can print nil, atoms, lists, nested lists,
  multi-byte atoms, and recovered dynamic atom graphs for focused cases.
- **Multiple dispatch**: qfc4 can compile linked dispatch tables, miss paths,
  runtime argument class cells, mutable class cells, and mutable method
  pointers.
- **Optimization**: optional qfc4 rules prove constant folding, known-branch
  reduction, dead-code elimination, and focused tail-call lowering.

- [ ] **Task 5.1: Implement Garbage Collection**
  Replace the arena allocator with a general collector over arbitrary live
  Qfitzah objects. Current proofs are strong enough to guide the design, but
  they are not yet one reusable collector.
- [x] **Task 5.2: Compile Multiple Dispatch Tables**
  Compile dynamic linked dispatch tables and runtime lookup paths.
- [x] **Task 5.3: Add Basic Optimization Passes**
  Prove focused constant folding, known-branch reduction, dead-code
  elimination, and tail-call lowering.
- [ ] **Task 5.4: Execute Reproducibility Verification**
  Compile the Stage 5 compiler with Stage 4, then rebuild it with itself and
  verify byte-identical output.

## Next Step

The next meaningful Stage 5 step is to collapse the focused GC proofs into a
single reusable collector interface: root-set enumeration, object classification,
pair/atom relocation, forwarding lookup, scan traversal, and allocation retry
should become shared compiled routines instead of bespoke fixtures. Once that
exists, the compiler/runtime source can start replacing the remaining focused
proof programs.
