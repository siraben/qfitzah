# qmes: a GNU Mes interpreter in the rsc dialect

`bootstrap/qmes.scm` is a transliteration of GNU Mes 0.27.1's C core
(`third_party/mes/src/*.c`) into the rsc dialect. It is compiled by the Stage 4
rsc compiler and assembled by `asm.elf` into a native i386 ELF, and it runs
Mes's own boot chain and MesCC unmodified. This document is the design
reference for that interpreter: its value model, its explicit-stack VM, the
garbage collector, call/cc, the host-heap safepoint discipline, the fidelity
contract with the reference, and the x86_64 number variant.

The invocation recipes and the fixpoint gates live in `docs/mes-bootstrap.md`
and the `tools/` scripts. This document is about how the interpreter is built.


## 1. Value model

Mes represents a value ("SCM") as a small integer **index** into a flat array
of cells (`mes.h`: `struct scm { long type; union car; union cdr; }`; the cell
types are in `constants.h`). Cells reference each other by index, which is what
makes the Cheney-style GC and the explicit VM stack work. qmes mirrors this
exactly:

- **A Mes SCM is an rsc fixnum** — the cell index. Indices are `< arena size`
  (≤ 20e6), well inside rsc's 30-bit fixnum range, so an SCM is an immediate:
  it holds no host pointer.
- **The cell arena is one rsc vector** `g-cells` of `3 * NCELLS` raw 32-bit
  words, allocated once at startup. Cell `i`'s fields are the raw words at
  vector slots `3i` (type), `3i+1` (car), `3i+2` (cdr), accessed with
  `vec-raw-ref` / `vec-raw-set!` (raw machine words, bypassing rsc's tag
  interpretation) — because a Mes `car`/`cdr` holds an index and a Mes
  `value`/`length` holds a full 32-bit word.
- **32-bit values** (TNUMBER payloads, addresses, MesCC bit arithmetic) are
  **w32** boxes (a raw 32-bit word) with native add/sub/mul/div/and/or/xor/
  shl/shr/sar/compare. Cell fields move between the arena and w32 boxes via the
  raw accessors.
- **Fixed constant cells** occupy the low indices: `cell-nil`, `cell-f`,
  `cell-t`, `cell-dot`, `cell-arrow`, `cell-unspecified`, the `cell-vm-*` VM
  states, the `cell-symbol-*` and `<cell:*>` type symbols. They are initialized
  by a transliteration of `init_symbols_` (`symbol.c`) so that programs and the
  reader see the same identities Mes does.

qmes need **not** reproduce Mes's exact numeric cell indices — only identities
are ever observable (see §7). The C runs `init_symbols_` twice only because its
hash table does not exist on the first pass; qmes interns in one pass.

### 1.1 Strings and bytes

Mes gives TSTRING / TSYMBOL / TKEYWORD the layout `car = length`,
`cdr = <TBYTES cell>`, and the TBYTES cell's payload is the bytes. qmes keeps
the bytes in a **separate byte pool**, so a TBYTES cell is
`[TBYTES | length | byte-offset]` and TSTRING/TSYMBOL/TKEYWORD are
`[T | length | tbytes-cell-index]`. Every string operation goes through the one
TBYTES indirection, exactly as `string_equal_p`, `eq_p` on keywords, and
`hashq_` (which hashes the first two bytes) do in the C. Keeping bytes out of
the cell arena makes the arena homogeneous (every cell is a well-formed 3-word
cell), which simplifies the collector (§3).


## 2. The VM: eval-apply as an explicit-stack trampoline

`eval_apply()` (`eval-apply.c`) is one C function driven by four global
registers — R0 (env), R1 (expression/value), R2 (scratch/saved datum), R3
(continuation state) — an explicit stack `g_stack_array` growing **down** from
`STACK_SIZE`, and a dispatch chain that compares R3 against the `cell_vm_*`
state cells and `goto`s the matching label. `R3 == cell_unspecified` means
"return R1 to the C caller".

### 2.1 Registers, stack, frames

R0–R3 and `stkp` (the C's `g_stack`) are five rsc top-level variables mutated
with `set!`. Globals are chosen over a `regs` vector because every register
holds a fixnum (so a global slot is already reset-safe — §4), because `set!` on
a top-level variable is a single store in rsc codegen, and because the
transliteration then reads like the C.

The stack `g-stack` is its own raw-word vector, **not** part of `g-cells` (Mes
also keeps it separate) — every slot holds an SCM, never a w32 payload and
never a host value, which keeps it trivially reset-safe and makes the call/cc
snapshot a plain word copy. Frames are 5 words pushed downward
(`R3, R2, R1, R0, procedure`, with the procedure at `GC_FRAME_PROCEDURE = 4`),
per `gc_push_frame` / `gc_pop_frame`. `push_cc` is the only way a state
suspends into a subcomputation, and it performs the exact register dance the C
does: capture the caller's R0/R1 and the *new* R2/R3 into the frame, then
continue with the callee's R1/R0 and the caller's old R3.

### 2.2 One rsc procedure per state, tail calls for gotos

rsc has proper tail calls, so the rendering is mechanical:

- **Each C label becomes a top-level procedure `st-<label>`** taking no
  arguments and reading/writing the register globals. Every `goto lbl` becomes
  a tail call `(st-lbl)`.
- **The `eval_apply:` dispatch label becomes `(vm-dispatch)`**, a `cond` chain
  over `r3` in the C's dispatch order (which is roughly frequency-sorted).
- C locals inside a state body become `let*` locals of that state's procedure.
  This is sound because eval_apply's C locals **never survive a dispatch
  round-trip**: whenever the C pushes a frame and gotos, every local it later
  reads is re-derived from R1/R2 after the frame pops.
- The two loop-with-embedded-label states (`begin`, `begin_expand`) split into
  a loop procedure plus a re-entry state procedure that tail-calls back into
  the loop, with the accumulator riding as a procedure argument.

Two C labels (`call_with_current_continuation`, `call_with_values`) are entered
only by direct goto, never via R3, so they become plain procedures, not
dispatch entries.

**The tail-call rule** (the invariant the transliteration must keep): `st-*`
procedures and `vm-dispatch` may be invoked only in tail position (or, for the
nested trampoline, via `vm-run-nested` from a builtin — §5). Leaf helpers
(pairlis, lookup-binding, equal2?, the reader, the printer) must never call
into an `st-*` state. This is what makes the host-heap reset sound (§4) and
what keeps the machine running in constant host stack.

### 2.3 The states

The VM implements the full Mes state set — the evlis chain, apply/apply2, the
eval dispatch and its continuations, `if`/`if-expr`, `begin`/`begin-eval`,
`eval-define`, `eval-set!`, the `macro-expand` family, the `begin-expand`
top-level driver, `eval-macro-expand`, plus `call-with-current-continuation2`
and `call-with-values2`. Three states — `core:apply`, `core:eval-expanded`,
`core:eval` — are also *user-visible values*: they are the VM-state cells bound
in the initial environment and applied as procedures.

Everything in the state bodies is a direct transliteration of the C, including
the parts that look wrong and must **not** be "fixed": `eval2`'s use of the
un-evaluated operator position `R2->car`, the closure-application double-cdr
that drops the captured env's own head entry, and the in-place mutation of
program cells by the macro walker. The per-rung differential against the
reference (§8 of `docs/mes-bootstrap.md`) is what catches any drift at the
smallest reproducer.


## 3. Garbage collection

### 3.1 The C collector

Mes's GC (`gc.c`) is **not** a classic two-semispace scheme; it is
copy-up-then-slide-back within one arena:

1. **News space** begins at the current `g_free`. The arena is allocated with
   `JAM_SIZE` slack beyond `ARENA_SIZE`, and `JAM_SIZE` is re-tuned to 1.5× the
   live set after each collection, so the top of the arena always has room for
   one live-set copy.
2. `gc_` copies roots in a **fixed order**: the fixed-cell region
   `[cell_nil, g_symbol_max)` first, cell by cell, in address order, then
   `g_symbols`, `g_macros`, `g_ports`, `scm_hash_table_type`,
   `scm_variable_type`, `M0`, `M1`, then the live stack. R0–R3 ride on the
   stack because `gc()` brackets the whole thing with `gc_push_frame` /
   `gc_pop_frame`.
3. `gc_copy` forwards via a `TBROKEN_HEART` whose car points at the new cell;
   TSTRUCT/TVECTOR copy header + contiguous body inline; TBYTES copies its byte
   run.
4. `gc_loop` is a Cheney scan classifying pointer fields by cell type.
5. `gc_flip` block-moves news back to the arena base, adding `-dist` to every
   pointer field, then shifts the root globals and the live stack slots.

**The crucial consequence** of step 2 + step 5: because the fixed cells are all
live, copied first, and copied in address order, they land back at exactly
their original indices after the flip. `cell_nil`, every `cell_vm_*`, every
`cell_symbol_*` are numerically stable across GC — which is why the C never
rewrites those globals, and why qmes inherits stable fixed cells for free by
copying its fixed region first in index order.

**Trigger:** collection happens **only** at the three `gc_check` sites (the
eval application push, the begin loop, the begin_expand loop), where all live
SCMs are reachable from R0-R3 / the g-stack / the named globals. That contract
is what makes precise copying GC possible without scanning host frames.

### 3.2 The qmes rendering

The transliteration is direct because the cell model was designed for it: an
SCM is a fixnum index, so `dist` is a fixnum delta and a broken heart is
`[TBROKEN-HEART | new-index | 0]`. `qgc` pushes R0-R3 onto g-stack, runs the
five steps over `g-cells`, and pops. Roots are visited in `gc_`'s exact order,
mapped to the qmes globals (fixed region → `sym-table` → macros → ports →
type structs → M0 → M1 → live stack). The C's TBYTES byte-run special case
drops out entirely: a qmes TBYTES cdr is a pool offset, not a pointer, so it is
excluded from the cdr relocation list (behavior-identical to the C, whose
"relocated" TBYTES cdr is immediately overwritten by the byte memcpy).

Arena growth (`gc_up_arena`) is not ported: the fixpoint harness pins
`MES_ARENA = MES_MAX_ARENA`, which disables doubling in the reference too.

### 3.3 The byte pool: paired two-space compaction

The bytes live in a separate pool, so the collector extends to them with a
paired copy: two pool strings `g-bytes-a` / `g-bytes-b` of equal size, a
current-pool global, and `byte-free`. When `gc-copy` copies a TBYTES cell it
also copies its byte run into the *other* pool and writes the new offset into
the copied cell; sharing is preserved automatically because strings/symbols/
keywords reference bytes only *through* a TBYTES cell, and each TBYTES cell is
forwarded exactly once. At flip, the pool roles swap and the old pool's
contents die wholesale.


## 4. The host-heap safepoint

qmes runs on the rsc runtime, whose host pair heap is a bump allocator
reclaimed wholesale by `host-heap-reset!`. The safepoint mechanism recycles the
per-step host garbage (arg-list pairs, env frames, w32 boxes) that rsc's
calling convention conses, while all durable qmes state persists in pre-mark
storage.

### 4.1 Placement and soundness

`(host-heap-reset! floor)` is the **first expression of `vm-dispatch`** and
appears nowhere else. vm-dispatch is entered exactly at every frame pop — i.e.
at every subexpression completion — so per-step host garbage is reclaimed at
the highest safe frequency. `host-heap-reset!` is a bump-pointer store, O(1).

Soundness rests on three facts:

- **Nothing durable points into the host cell heap.** All durable VM state is
  `g-cells`, `g-bytes*`, `g-input`, `g-stack`, `g-chunk` — vectors/strings
  allocated *before* the mark, whose payloads live in rsc's *byte* arena (never
  reset) and whose handles sit in top-level global slots (pre-mark storage) —
  plus `r0-r3`, `stkp`, `m0`, the macro table, all fixnums.
- **vm-dispatch has no parameters and no free lexical variables**, so its own
  (now-freed) env frame is never read after the reset. The reset lives only at
  the top of a zero-argument procedure that touches nothing but globals.
- **All `st-*` states reach vm-dispatch only in tail position** (§2.2), so no
  state local is ever live across a reset.

### 4.2 The one host value that crosses the reset

`(host-heap-mark)` returns a w32 box allocated *at* the mark. The idiom
`floor = mark + 64` keeps a 64-byte pad below the floor that protects that box
(and the mark's own transients) from being reused. This is the single
deliberate exception to "no host value survives a reset", and it is safe
because the pad region is never re-allocated.

### 4.3 Audit disciplines

The three grep-level review rules that keep the safepoint sound:

1. Builtins run entirely between two dispatches; they may use host locals and
   strings freely but must persist results only into the arena (e.g.
   `string-append` copies into `g-bytes`, never stores an rsc string).
2. `qgc` may be invoked only from `gc-check` at the three transliterated sites
   (and the `gc` builtin), never from inside another builtin. No `st-*` state
   may hold a cell index local across an unbounded-allocation call — the C has
   the same rule implicitly (locals are not GC roots).
3. The reader/printer run over pre-allocated global buffers, not cached host
   strings.

A `qmes-no-reset` bisect switch (and a `MES_GC_STRESS`-style collect-at-every-
check switch) turn the reset/GC off for flushing discipline bugs early: any
behavior difference with a switch flipped is a violation.

### 4.4 The nested trampoline and the floor stack

The C re-enters `eval_apply` from four places: `primitive_load`, `error`
applying `throw`, `current_module_variable` applying an eval-closure, and
`display_` applying a struct printer. In qmes a host-recursive call to
`vm-dispatch` is almost fine — rsc has proper tail calls, the nested run is
internally iterative, and the sentinel protocol is balanced per nesting level
exactly as in C. The one conflict is the reset: the outer builtin's rsc env
frame lives in the host arena above the boot-time floor, and a naive nested
dispatch would reclaim it.

The fix makes the floor a **stack**: `vm-run-nested` — the only way to re-enter
the VM — pushes `mark+64` as a new floor, calls `vm-dispatch`, and pops the
floor on return; `vm-dispatch` resets to the current floor. Every host frame
belonging to an outer activation was allocated before the nested mark, hence
below the nested floor, hence protected; everything the nested run allocates
above its floor is reclaimed at its own dispatch cadence. With this, all four
re-entries transliterate literally.


## 5. call/cc, values, dynamic-wind, catch

The split mirrors the C exactly: **the core provides raw one-shot continuation
capture/restore, `values`, and stack introspection; scm.mes builds
dynamic-wind and the wrapped call/cc; catch.mes builds exceptions.**

- **Capture** happens at the `call_with_current_continuation` label with a
  **double snapshot**: capture the stack into a fresh TVECTOR, make
  `x = TCONTINUATION`, push a frame, apply the proc; then in the `cc2` state
  **re-snapshot** the stack (now including the just-pushed frame) into the
  continuation's cdr and return. The second snapshot is what makes returning
  *through* the capture point work when the continuation is invoked later.
  Transliterate literally.
- **Restore** copies the captured vector back to the stack top, sets
  `stkp = STACK-SIZE − len`, and sets the single value into R1.
- A continuation's captured stack is an ordinary TVECTOR of SCMs, so the
  collector relocates its slots like any vector — no GC special case.
- **Nesting caveat (inherited, not new):** a continuation invoked from a
  different eval_apply nesting level than its capture restores the g-stack but
  not the host recursion — undefined in the C reference too. boot-5's actual
  uses never cross levels; the transliteration reproduces the C's nesting
  exactly, so behavior matches by construction. Do not "fix" this.


## 6. Environments, closures, modules

Mes environments are **two-level**. The lexical level is an alist in R0 of
`(name . value)` handle pairs whose first entry, inside a lambda body, is the
marker `(*closure* . env-tail)` — that is how the evaluator distinguishes a
global define from a local one. The global level lives in **M0**, a hashq table
mapping symbol → **variable** (a struct whose value is at field 3), built at
startup from the builtin alist. Lookup wraps a found handle in a TBINDING;
`lookup_value` derefs it (lexical → handle cdr; global → variable ref).

The variable indirection through M0 is what makes global redefine and set!
reach the *same* variable cell that every earlier closure's lookup goes
through. The dependency spine is small leaf code with no VM interaction:
vector → struct → hashq → variable → module (with the eval-closure branch
guarded off until the module system boots) → lookup-binding.

`expand_variable` rewrites free symbol occurrences into TBINDING cells in place
(creating M0 variables for still-undefined names — the forward-reference
mechanism), skipping quoted forms, formals, and `current-environment`. It rides
the global registers with an explicit worklist and a frame bracket, exactly as
the C does.

The `merged mesroot` rationale: `bin/mes-m2` reaches `(top-main)` only with a
*merged* module tree — `$MES_PREFIX/mes/module/` must overlay the top-level
`module/` half (getopt-long, mescc, srfi, ice-9, nyacc). The harness synthesizes
this merged root (`tools/make-mesroot.sh`); the source files under
`third_party/mes` are never patched, so both hosts load byte-identical sources.


## 7. The fidelity contract: what boot-5 actually observes

**Exact-index matching is NOT required. Semantic-layout matching IS.** Nothing
in boot-5 or the module chain compares SCM values against numeric cell indices,
and nothing observes intern order. What the chain does observe, exhaustively:

1. **`core:type` tag numbers**, via the `<cell:*>` bindings — so only internal
   consistency between `core:type` and those bindings is needed. qmes uses
   Mes's exact numeric type tags verbatim; they cost nothing and remove a class
   of doubt.
2. **Symbol identity through one obarray.** All dispatch is `eq?` on interned
   symbols. Intern order is unobservable (`hashq_` hashes the first two name
   bytes, never an address), so a moving GC is invisible to hash tables.
3. **Struct field offsets**, hardcoded in Scheme and pinned by the C: variable
   value at 3; hashq size at 3, buckets at 4; builtin `'builtin` at 2, name at
   3, arity at 4, function at 5; frame procedure at 3; module `OBARRAY 3`,
   `USES 4`, `EVAL_CLOSURE 6`; srfi-9 records; struct printer at 1.
4. **EOF is a TCHAR with value −1**, not a distinct object.
5. **`core:car`/`core:cdr` on non-pairs** as raw, unchecked field accessors
   (used on chars, bytes, closures for type introspection).
6. **The initial environment bindings**: self-bound specials, `%version`
   (= "0.27.1"), `%datadir`, `%arch`, `%compiler`, `%argv`, the `<cell:*>`
   numbers, `hash-table-type`, and the `(*closure* . a)` head entry.

The startup sequence transliterates `mes.c` main: read env vars, `open_boot`
with the full `%datadir` search, `gc_init`, `mes_environment`, `mes_builtins`
(the full census), M0/M1/`g_macros`, then read the boot forms through the port
layer, build the `%program` env, push a sentinel frame, set R3 to
`begin-expand`, take the host-heap mark, and run vm-dispatch to completion.


## 8. The x86_64 variant (qmes-64)

MesCC targeting x86_64 performs **real 64-bit host arithmetic** (not just
read/print): `hex2:immediate8` computes `modulo o #x100000000`, `int->bv64`
arithmetic-shifts by up to −56, and signed compares run against 2^31. Every
negative C literal (`-1` is ubiquitous) produces a 64-bit immediate whose low
word `0xffffffff` exceeds the signed-32-bit range and the rsc fixnum. So a
32-bit-value host cannot run `mescc --arch=x86_64` faithfully — proven: the
i386 `bin/mes-m2` cross-hosting `--arch=x86_64` dies `divide-by-zero: (-1)`
(the literal `#x100000000` wraps to 0, and `(modulo -1 0)` faults). A genuine
64-bit reference (`bin/mes-m2-64`, a native amd64 M2-Planet build) is
mandatory.

qmes-64 stays an **i386 process**; only its TNUMBER value width changes.

### 8.1 Representation: `[TNUMBER | hi | lo]`

A TNUMBER puts the high 32 bits in the (otherwise zero) car word — the
**existing 3-word cell**, no stride change, no arena resize. This beats a
4-word cell because **the collector is provably untouched**: the collector
classifies pointer fields by type list, and TNUMBER's car and cdr are both
copied raw, so storing `hi` in the car requires zero GC edits. A
sign-extending `make-number-w` keeps every legacy single-word call site
(string-length, char->integer, struct indices, indices, fds, lengths — all
< 2^30) correct without change.

(Divergence note: mes-m2-64's number cells have car = 0, so `core:car` of a
number returns `hi` under qmes-64 instead of 0. No boot-5, nyacc, or mescc code
calls `core:car` on a number; the one-line fallback exists if a rung ever trips
on it.)

### 8.2 The w64 layer: pure Scheme over the w32 prims

`bootstrap/qmes-w64.scm` is a pure-Scheme w64 library over the existing w32
primitives — **no runtime prim changes**, so the committed
`bootstrap/rsc-runtime.qf1` and the closed Stage-4 rsc / asm.elf fixpoints are
untouched. A 64-bit value is threaded in-flight as two w32 boxes; where a
helper returns both (divmod) it returns a host pair, transient and reclaimed by
the safepoint. The target semantics are **amd64 C `long` as M2-Planet compiles
math.c**: two's-complement wrap mod 2^64, arithmetic right shift for signed,
and **shift counts masked `& 63`** (amd64 SHL/SAR mask counts). Add carries via
`w32-ult?`; multiply schoolbook over 16-bit limbs; divide by long division in
16-bit chunks for small divisors, word-move for the 2^32 case, and a
64-iteration shift-subtract for the general (corpus-rare) case.

### 8.3 One source, a build variant

rsc compiles top-level defines into ordered startup assignments through global
value cells, so a later define of the same name wins for every subsequent call.
qmes-64 is therefore the same source with an override file appended:
`cat rsc-prelude qmes.scm qmes-w64.scm qmes-main.scm` (the final `(qmain)` line
is split into `qmes-main.scm` so the override lands before it). The i386 build
omits the w64 file and is byte-identical. The override set is the w64 library,
the number constructors, the 13 math builtins, the decimal/radix reader and
printer paths, the number-equality sites, and `%arch = "x86_64"`; everything
else in qmes is width-independent (indices, offsets, lengths, port ids, and the
two-byte hash functions).


## 9. The C-quirk emulations

qmes deliberately mirrors the reference's C-`long` quirks, because the fixpoint
compares against a C-compiled Mes byte-for-byte:

- **`b-modulo` / `b-div` / `b-ash` mask shift counts mod 32** (mod 64 in the
  w64 layer), matching x86's shift-count masking. The offsetof-via-`ash 32`
  path in MesCC's static initializers depends on this: a bug where `b-ash` did
  *not* mask the shift count zeroed the high word of `offsetof(TCCState,f)`
  static initializers in `libtcc.c` (where MesCC — via an upstream quirk —
  emits the offset as one 64-bit value with the low word *repeated*), causing
  the one divergence in the tcc T1 sweep. Masking mod 32/64 restores byte
  parity.
- The math builtins keep the C's sign-fold and modulo raise-loop shapes
  line-by-line so signed division and modulo match the reference exactly.


## 10. The rsc-runtime address space (a memory pitfall worth recording)

The rsc runtime lays out its host heap arithmetically from the `CodeEnd` label:
pair-cell heap at `[CodeEnd, +0x2000_0000)` (512 MiB), byte heap at
`[+0x2000_0000, +0x6000_0000)` (1 GiB), I/O buffers above, then one `brk` to
the top. The ELF LOAD segment's **bss size must cover the whole span**
(`bootstrap/rsc.scm`), because under Linux brk randomization (ASLR) the kernel
places `start_brk` a random 0–32 MiB *above* the segment end. If the bss size
is too small (it was once 256 MiB against a 512 MiB pair heap), an **unmapped
hole** opens between bss end and the brk'd heap, in the middle of what the
runtime believes is its pair heap. The pair allocator has no bounds check, so a
large enough live set (first tripped under GC stress at boot rung B4's
`(mes scm)`, ~300–600K live cells, where one collection's transients burn
through the mapped bss) stores into the hole and SIGSEGVs. The fix is to size
the LOAD segment's bss to cover the entire declared heap span plus the ASLR
gap. This is why the runtime's bss constant is the full `0x6200_0000`.
