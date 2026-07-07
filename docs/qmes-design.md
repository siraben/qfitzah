# qmes design (P2–P4): a Mes-core-compatible interpreter in the rsc dialect

qmes is a transliteration of GNU Mes's C core (`third_party/mes/src/*.c`) into
the rsc dialect, compiled by the Stage 4 rsc compiler and assembled by the seed
into a native i386 ELF. It runs Mes's own boot chain and MesCC unmodified. This
document fixes the representation and the milestone-1 subset; it is the P2
blueprint.

## Value model

Mes represents a value ("SCM") as a small integer **index** into a flat array
of 3-word cells `g_cells` (`include/mes/mes.h:28-56`: `struct scm { long type;
union car; union cdr; }`; 18 cell types in `constants.h:24-44`). Cells reference
each other by index, which is what makes the Cheney GC and the explicit VM stack
work.

qmes mirrors this exactly:

- **A Mes SCM is an rsc fixnum** — the cell index. Indices are `< arena size`
  (≤ 20e6), well inside rsc's 30-bit fixnum range.
- **The cell arena is one rsc vector** `g-cells` of `3 * NCELLS` raw 32-bit
  words, allocated once at startup. Cell `i`'s fields are the raw words at
  vector slots `3i` (type), `3i+1` (car), `3i+2` (cdr), accessed with the P1
  substrate primitives `vec-raw-ref`/`vec-raw-set!` (raw machine words boxed as
  w32, bypassing rsc's tag interpretation) — because a Mes `car`/`cdr` holds an
  index and a Mes `value`/`length` holds a full 32-bit `long`.
- **32-bit values** (TNUMBER payloads, addresses, MesCC bit arithmetic) are P1
  **w32** boxes (subtype-5 object: raw 32-bit word in the cdr) with native
  add/sub/mul/div/and/or/xor/shl/shr/sar/compare. Cell fields move between the
  arena and w32 boxes via `vec-raw-ref`/`vec-raw-set!`.
- **Fixed constant cells** occupy low indices matching Mes's boot layout
  (`cell_nil`, `cell_f`, `cell_t`, `cell_dot`, `cell_unspecified`,
  `cell_symbol_*`, the `cell_vm_*` states, …), initialized by an
  `init-symbols`/`gc-init-cells` transliteration so that programs and the
  reader see the same identities Mes does.

**Why the host-heap safepoint reset (P1 gap 6) is sound here.** Every
persistent qmes datum is either (a) the `g-cells` vector, allocated once before
the safepoint mark, or (b) a Mes SCM, which is an rsc *fixnum* (immediate — no
host pointer). The only host allocations after the mark are the arg-list pairs
and env frames rsc's calling convention conses per call; none of qmes's durable
state points into them. So resetting the host cell arena to the mark at the VM
trampoline cannot dangle anything. The index-based cell model turns gap 6 from a
discipline into a structural guarantee. (Strings/bytes qmes builds live in the
arena as TSTRING/TBYTES cells backed by a qmes-owned byte region, not host
strings, so they survive too.)

## The VM (transliterating `src/eval-apply.c`)

Mes's evaluator is an explicit-stack trampoline: four registers R0 (env), R1
(expression), R2 (scratch/value), R3 (continuation state), a `g_stack` array,
and ~25 `cell_vm_*` states dispatched by a `goto` chain (`eval-apply.c:443-470`).
Special forms quote/lambda/if/set!/begin/define/define-macro are handled in the
state machine; proper tail calls and `call/cc` (a snapshot of `g_stack` into a
vector, `eval-apply.c:996-1010`) fall out of it.

qmes port:

- R0–R3 are four slots of a small rsc vector `regs` (fixnum SCM values),
  allocated at startup.
- `g_stack` is a qmes-owned region (arena vector words); `gc_push_frame`/
  `gc_pop_frame` (5-word frames, `constants.h:38`) push/pop R0–R3 + a procedure
  slot. This is also the continuation representation.
- The `goto` dispatch becomes a top-level trampoline loop in rsc: a tail-called
  `(vm-step)` that reads R3, branches to the matching state handler, and
  tail-loops. **The safepoint** `host-heap-mark`/`host-heap-reset!` brackets each
  trampoline turn: mark on entry, reset before the next step, so per-step host
  conses are reclaimed while all Mes state (arena + fixnum registers) persists.
- Because rsc has proper tail calls, the whole state machine is ordinary
  tail-recursive rsc code; no host stack growth.

## Reader, printer, builtins

- **Reader** (`src/reader.c` port): milestone 1 needs decimal integers,
  `#t`/`#f`, strings, symbols (interned into the arena symbol table), `quote`
  via `'`, and lists incl. dotted pairs. Full Mes reader syntax (`#x/#o/#b`,
  `#(`, `#;`, `#|…|#`, keywords, char names) lands in P3. The reader's own
  *source* stays inside the sc1-reader subset that compiles it.
- **Printer** (`src/display.c` port): `display`/`write` of the milestone value
  set; full write in P3.
- **Builtins** (`mes_builtins`, `src/builtins.c:116-332`, ~174 total): each is
  ordinary rsc code over the arena. Milestone 1 needs only `cons car cdr list
  exit` plus `eval`/`apply` core; the census in `docs/mes-bootstrap-plan.md`
  §2 gap-8 lists the rest (hash/struct/variable/port/keyword) for P3.

## `main` and boot loading (`src/mes.c:126-200`)

`open_boot` reads `MES_BOOT` (default `boot-5.scm`) from `MES_PREFIX/mes/module/
mes/` (then `share/mes`, then `$srcdest`), via `getenv` + `sys-open` (P1). It
reads the whole file and evaluates each top-level form. Env parity for the
fixpoint runs (`%version`, `MES_VERSION`, `MES_PREFIX`, `MES_ARENA`, `LANG=`) is
pinned by the harness (plan §5).

## Milestone 1 (P2 exit criterion)

`qmes.elf` (rsc-compiled, seed-assembled) runs
`MES_BOOT=third_party/mes/scaffold/boot/<t>.scm ./qmes.elf` for
`t ∈ {00-zero, 01-true, 02-symbol, 03-string, 04-quote, 05-list, 06-tick,
07-if, 08-if-if, 10-cons, 11-list, 12-car, 13-cdr, 14-exit}` and each exit
status matches the committed reference `bin/mes-m2`
(`tests/mes-reference-bootstatus.txt`, all 0). That single differential loop is
the P2 test, wired into `tests/run.sh` behind the qfitzah suite.

## Sequence after milestone 1

Follow the `scaffold/boot` numbering (plan §4): 15–17 (display/strings/
keywords), 2x–3x (define/lambda/closures/capture), 38 (string ports), 40–4f
(define-macro/quasiquote/let), 50–53 (keywords/primitive-load/modules), 60
(syntax-rules via define-macro), then call-cc/gc/memory, then
`MES_BOOT=boot-5.scm` to `(top-main)`, then `mescc -S scaffold/hello.c`
byte-equal to reference (P5, needs vendored nyacc), then the F1/F2/F3 fixpoint
sweep (P6).
