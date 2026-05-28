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
direct calls in that range; widening to fully automatic short-vs-near jump
selection remains part of making this stage general.

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
enough for `emit_byte`, recursive `emit_bytes`, or the full interpreter.
`bootstrap/stage4-emit-byte.qf1` extends this by compiling an `emit_byte`-shaped
routine that calls `Nybble` twice, combines the nybbles, and writes byte `41`
to stdout from the generated ELF.

Reader progress: the seed runtime now accumulates parenthesized forms across
physical lines and treats embedded newlines as whitespace, which makes staged
rules and programs more readable. Rules can be written either as the traditional
two-form logical record or as an explicit multi-line `(Rule pattern replacement)`
directive. The Stage 3 macro assembler, the Stage 4 compiler source, and their
sample inputs now use that readable multi-line style.

- [ ] **Task 5.1: Implement Garbage Collection (GC)**
  Implement a basic allocator and garbage collector (such as a stop-and-copy or mark-and-sweep collector) to replace the non-reclaimed arena allocator.
- [ ] **Task 5.2: Compile Multiple Dispatch Tables**
  Implement compilation of dynamic multiple-dispatch method tables, mapping method signatures to concrete runtime addresses.
- [ ] **Task 5.3: Add Basic Optimization Passes**
  Integrate optimization passes in the compiler, including tail-call optimization (TCO), constant folding, and dead-code elimination.
- [ ] **Task 5.4: Execute Reproducibility Verification**
  Compile the Stage 5 compiler using the Stage 4 compiler, and then compile the Stage 5 compiler with itself to verify binary identity (reproducibility).
