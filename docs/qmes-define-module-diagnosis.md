# qmes MesCC-blocking crash ("define-module import path") — diagnosis

Date: 2026-07-08.  Branch `mes-bootstrap` at `8b7de40` (clean tree + this doc
and `tests/repro/`).  Status: **root cause identified and experimentally
proven end-to-end** (diagnosis only; no fix applied).

**One line: this is not a module-system bug.  The rsc host pair heap (512 MiB
bump allocator, no bounds check, reclaimed only by reset-to-floor at
dispatch entry) overflows into the adjacent `g-cells` arena during the deep
nested-`primitive-load` chain that module loading creates; the overflow
silently smashes the low (fixed/symbol) cells, and the evaluator then walks
off a cliff.**  The GC is innocent (`gc-count=0` is *correct* at the moment
of primary corruption), and the `define-module`-vs-`use-modules`
discriminator is an allocation-volume cliff, not a semantic divergence.

---

## 1. Failure statement and independently verified locus

### 1.1 Reproductions (all measured on this tree, this machine)

- `bash tools/mescc-smoke.sh ./qmes.elf third_party/mes/scaffold/hello.c out.s`
  → SIGSEGV (rc 139), no `.s`.  Same command with `bin/mes-m2` → 422-byte
  `.s`, rc 0.  ✔ reproduced.
- Minimal one-line repro (committed): a script containing just
  `(use-modules (mescc preprocess))`, loaded through the full module system
  with the smoke environment (`tests/repro/run-hostheap-repro.sh ./qmes.elf
  tests/repro/use-mescc-preprocess.scm`) → **core dump**.  Under `bin/mes-m2`
  → `SURVIVED`.  ✔
- Controlled fixture (committed): `tests/repro/use-hostheap-cliff.scm` loads
  `(test hostheap-cliff)` = a rename of `mescc/preprocess.scm` →
  **core dump** under qmes, `SURVIVED` under mes-m2.  ✔

### 1.2 The prior localization is wrong in the load-bearing detail

The claim "a `define-module` with the 8 `#:use-module`s + a trivial body
CRASHES, but the same 8 modules via flat `(use-modules …)` SUCCEED" was
re-tested properly (through the module loader, post-boot, never `MES_BOOT`):

| variant (all with the same 8 imports) | result |
|---|---|
| flat `(use-modules …)` of all 8, top level | PASS |
| `define-module` + 8 uses, **trivial body**, loaded as a module (`v2`) | **PASS** |
| `define-module` + 8 uses as top-level script header (`dm8`) | PASS |
| `define-module` + 8 uses + preprocess.scm body **minus its last define** (`v8`, source lines 33–142) | PASS |
| … + the last define `ast-strip-const` (`v9` = full file) | **CRASH** |
| `v8` + two *renamed copies* of `ast-strip-inline` as padding (`v10`) | **exit 1, silent** (different failure, same bug) |
| header + **only** `ast-strip-const` (`v11`) | PASS |
| single `#:use-module (nyacc lang c99 parser)`, or flat use of it | PASS |

So: the trivial-body 8-uses define-module does **not** crash; the crash needs
~the full preprocess.scm *source text*; the specific trailing define is
irrelevant (v11 passes alone, v10 fails differently with padding).  There is
no minimal-#:use-module count — the discriminator is **total volume with a
sharp cliff**, and the measured cliff headroom is ~155 KiB of *host heap*
(§1.4), which a ~600-byte source-file delta (times the reader's ~100–1000×
host-transient amplification) easily spans.  This also explains why the bug
was mislocalized: every A/B that shrinks the file "fixes" it.

### 1.3 The proven causal chain (v9 fixture, timed cores at 8–65 s + fault core)

All numbers read out of core dumps with the GV/proc symbol map recovered from
`build/qmes/qmes.qfasm` + disassembly (method in §4.3).  Key globals:
`cell-free@0x8089f90`, `gc-count@0x808992c`, host pair-heap bump pointer
`GCellFree@0x808d3c4` (static of the runtime `Cons` at `0x808c584`); layout:
image `0x8048000–0x808f000`, host pair heap `[0x808f000, 0x2808f000)`
(512 MiB), byte heap `[0x2808f000, 0x6808f000)` — `g-cells` data at
`0x2809e558` (66 M words = 22 M cells × 12 B), then `g-stack` (20 MB), pools
A/B (2×16 MiB), I/O buffers to `0x6a08f000` = end of mapping.

| T | cell-free | GCellFree (host pair heap) | state |
|---|---|---|---|
| 8 s | 13.0 M | `0x1973c2d0` = base+292 MiB | sane eval (st-apply-closure) |
| 10 s | 17.1 M | `0x1b1f3c30` = base+320 MiB | **inside the reader**, `reader-read-list` recursion over a string port — reading `nyacc/lang/c99/mach.d/c99-tab.scm` (the last trace line is `;;; read …/c99-tab.scm`); low cells 0–333 still pristine (`cell 333 = symbol "cons"`) |
| 11 s | 18.9 M | `0x28069048` = **512 MiB ceiling − 155 KiB** | **low cells 0..≥333 smashed** with host-heap pair words (tagged values + pointers `0x280axxxx` into the overflow region); `cell 333` (`cons`) now reads `(1251, …)` — its old byte-pool offset shifted into the type slot |
| 12–14 s | 20.3 M / 23.2 M | pinned at `0x28069xxx` | **infinite apply loop** (below), `st-apply-fallthrough` on stack |
| 35–65 s | 50.8 M → 92.27 M | pinned | loop continues; byte pools A/B completely overwritten by the repeating 12-byte record `(TPAIR, 333, 3)` |
| fault | **92,269,455** | pinned | `gc-count=0`; SIGSEGV in `alloc` called from `st-apply2`: the *first word-write of freshly allocated cell 92,269,454*, whose address `0x6a08f000` is the first byte past the **entire** mapping (verified: `0x2809e558 + 4·(3·92,269,454) = 0x6a08f000`, value stored = 7 = TPAIR) |

So, in order:

1. **Host pair-heap high-water ratchets across the nested module-load chain.**
   `vm-run-nested` (qmes.scm:2421) sets `floor` = *current mark* + 64 at every
   re-entry; `b-primitive-load` (qmes.scm:2431) does `read-all-forms` — one
   host call, megabytes of transients — *before* entering the nested run, so
   every deeper floor sits above every enclosing load's read/eval garbage.
   Loading `(mescc preprocess)`'s graph nests `primitive-load-eval` 4 deep
   (fault-core stack: `qmain → st-apply → (primitive-load-eval →
   vm-run-nested → st-apply)×4 → st-apply2 → alloc`) and the bump pointer is
   already at **292 MiB of 512 MiB** by T=8 s.
2. **One dispatch step crosses the ceiling.**  The read of `c99-tab.scm`
   (100,163 bytes, one giant nested list, read in ONE `b-primitive-load` host
   call — no `host-heap-reset!` is possible mid-call) pushes `GCellFree` past
   `0x2808f000`.  `Cons` (runtime, `0x808c584`) has **no bounds check**; the
   next stores land in the byte-heap region, i.e. **on `g-cells[0..]`**: the
   fixed cells, interned symbols, everything the interpreter lives on.
   (Thanks to commit 4bfedc5 the whole span is mapped, so this is *silent*.)
3. **The evaluator then applies a smashed object.**  Cell 333 — the symbol
   `cons` — now has type word 1251.  `check-apply` (qmes.scm:1669) only
   rejects {#f,#t,nil,unspec,undefined,TCHAR,TNUMBER,TSTRING,TBH}; garbage
   type 1251 passes.  `st-apply` (qmes.scm:~2560) falls through to
   `st-apply-fallthrough`: push `vm-apply2`, re-`st-eval` the head; `st-eval`
   of a garbage-typed cell takes the `(else (st-vm-return))` arm; `st-vm-return`
   pops `vm-apply2`; `st-apply2` re-conses `(333 . 3)` and calls `st-apply`
   again — **an infinite cycle allocating one pair per iteration whose states
   (`st-apply`, `st-apply2`, `st-eval` non-pair arm, `st-vm-return`) contain
   none of the three `gc-check` sites** (qmes.scm:2686, 2833, 2849).
4. **The cell arena runs away unchecked.**  `alloc-n`'s cap check is
   debug-gated (qmes.scm:67, `QMES_DEBUG_ERR` only; contrast Mes `src/gc.c
   alloc`/`make_cell`, which *unconditionally* `assert_msg "out of memory"`).
   `cell-free` marches 19.8 M → 92.27 M (overwriting `g-stack`, both byte
   pools, the I/O buffers — all self-consistently, all mapped) and dies at
   the first unmapped byte.

Proven negatives (each measured, not inferred):
- **qgc was never entered** — unconditional breakpoint at `qgc` (0x806cf07),
  zero hits over the whole crashing run (exact-env gdb reproduction, same
  fault EIP/cell-free as the native core).
- **gc-check was never called with `cell-free ≥ 19.8 M`** — conditional
  breakpoint `*(unsigned*)0x8089f90 >= 0x4b86f01` at gc-check (0x806cc53),
  zero hits before SIGSEGV.  Below the threshold gc-check runs millions of
  times and `gc-want?` correctly returns #f (ARENA-CELLS=20 M, GC-SAFETY=200 K,
  stress=0, pressure=0 — all verified in the fault core).  GC works when
  reachable: full boot at `MES_ARENA=3e6` collects once (`gc-count=1`) and is
  byte-exact.
- The **original mescc-smoke fault core** (current binary) shows the same
  primary event with a *shorter* downstream path: `GCellFree = 0x2930ee18` =
  **19.4 MiB past the pair-heap ceiling, inside `g-cells`**, `cell-free` only
  15.5 M (arena not full — matching the earlier "9 M/22 M" observation),
  `gc-count=0`.  Same root cause, different post-corruption walk (garbage
  read instead of runaway loop).  The v10 "silent exit 1" and the
  `QMES_DEBUG_ERR=1` run's `;;; qmes-error head-undefined define` are two more
  post-corruption walks; which one you get shifts with byte-level layout
  (env block, file sizes) — exactly the reported "layout-sensitive" behavior.

### 1.4 Why define-module vs flat use-modules "discriminated"

Both load the identical module graph.  They differ in nesting shape and in
how much read/eval host garbage sits below the floors when `c99-tab.scm` is
finally read; at T=11 s the surviving headroom is ~155 KiB out of 512 MiB
(0x2808f000 − 0x28069048).  Any change worth a few hundred KiB of host
transients — one more `#:use-module`, 17 more source lines, a different env
block — flips the outcome.  All the "discriminators" collected so far
(define-module vs use-modules, 8-uses vs trivial body, v8 vs v9) are
positions relative to this cliff.

---

## 2. Ranked root-cause hypotheses

### #1 — PROVEN: host pair-heap overflow into `g-cells` during nested module loading

- **qmes does X:** `bootstrap/rsc-runtime.qf1` lays the host pair heap at
  `[CodeEnd, CodeEnd+0x2000_0000)` immediately below the byte heap that
  contains `g-cells`; `Cons` bump-allocates with no limit check.
  `bootstrap/qmes.scm` reclaims host transients only via `host-heap-reset!
  floor` at `vm-dispatch` entry (qmes.scm:2488), with `floor` ratcheted
  upward by every `vm-run-nested` (2421) and never lowered during a load
  chain; `b-primitive-load` (2431) reads a whole file in one un-resettable
  host call; `alloc-n` (64) checks the cell cap only under `QMES_DEBUG_ERR`.
- **Mes does Y:** C Mes has no host heap at all — the reader allocates Mes
  cells directly; `alloc`/`make_cell` (src/gc.c:150-173) hard-abort on arena
  overflow; `gc_check` sites are identical (eval-apply.c:764/898/928) but can
  never be starved by a host loop because there are none.
- **Why a "wrong index":** the overflowed host pairs are written *as raw
  words over cell records*, so subsequent `cell-type`/`cell-car` reads return
  misaligned garbage (e.g. `cons`'s byte offset 1251 read as its type) —
  every downstream deref is a wrong index into `g-cells`; the specific
  faulting word depends on where the walk lands (SIGSEGV / SIGFPE `size=0` /
  `head-undefined` / silent exit).
- **Test (done, positive):** timeline cores above; `GCellFree` crossing
  `0x2808f000` exactly bracketed by the last pristine and first smashed
  low-cell snapshots (T=10 → T=11); original-workload core 19.4 MiB deep into
  `g-cells`.  **Confirm-after-fix:** with any of the §4.1 fixes,
  `tests/repro/run-hostheap-repro.sh ./qmes.elf tests/repro/use-mescc-preprocess.scm`
  prints `SURVIVED`, and `tools/mescc-smoke.sh ./qmes.elf …/hello.c` emits a
  `.s` (byte-compare to `bin/mes-m2`'s).

### #2 — REAL, SECONDARY (will bite MesCC next, not the crash): reader named-character / radix gaps

- **qmes does X:** `char-name->char` (qmes.scm:1288) knows only
  `space/newline/tab` and otherwise returns the **first letter** of the name:
  `#\nul→#\n`, `#\alarm→#\a`, `#\backspace→#\b`, `#\vtab→#\v`, `#\page→#\p`,
  `#\return→#\r`, `#\bel/#\bs/#\vt/#\np/#\cr/#\esc` likewise; no octal
  `#\0NN`, no `#\xNN`.  `reader-read-hash` (1264) routes `#x/#b/#o/#'/#`/#,`
  to the read-next-sexp placeholder.
- **Mes does Y:** `reader_read_character` (src/reader.c) implements the full
  name table incl. nyacc abbreviations, octal and hex.
- **Evidence:** with `MES_DEBUG=2`, qmes's module-load trace prints
  `*file-name => "/home/sir\a\be\0/qfitz\ah/\build/...\0y\acc/l\a\0g/..."` —
  the write-mode escaper in `mes/display.mes` compares against `#\nul`,
  `#\alarm`, `#\backspace`, `#\vtab`, `#\page` literals which qmes read as
  `#\n`,`#\a`,`#\b`,`#\v`,`#\p`; mes-m2 prints the same strings clean.  The
  underlying strings are fine — but the same mis-read literals are *live
  data* in the MesCC chain: `srfi/srfi-14.mes:38` (`char-set:whitespace` gets
  `p r v` instead of FF/CR/VT), `nyacc/lex.scm:296-301` (C string-escape
  table), `nyacc/lang/c99/parser.scm:264` (`#\return`), and `#x` literals in
  `mescc/M1.scm`, `mescc/compile.scm`, `mescc/as.scm`, `nyacc/lex.scm`.
- **Test:** `./qmes.elf -c '(write (string #\nul #\alarm #\backspace #\tab
  #\vtab #\page #\return))'` vs `bin/mes-m2` (byte-compare); after the #1 fix,
  the mescc smoke `.s` byte-compare will catch the rest.

### #3 — HYGIENE (why this was mislocalized twice; fix alongside #1): zero tripwires on either allocator

- `Cons`/`AllocObj` (rsc-runtime) have no ceiling check; `alloc-n`'s check is
  debug-only and guards the *wrong* allocator for this bug; `qfail` exits
  silently unless `QMES_DEBUG_ERR=1`.  Every overflow is silent corruption.
- **Test:** with tripwires added (§4.2), the repro must die with a one-line
  stderr message instead of a core; the byte-exact 20e6 gates must not change.

### #4 — LATENT, LOW PRIORITY: the apply-fallthrough cycle is gc-check-free

- The `st-apply → st-apply-fallthrough → st-eval(non-pair) → st-vm-return →
  st-apply2 → st-apply` cycle allocates without ever reaching a gc-check site.
  C Mes has the same state cycle (apply's default arm re-evals the head) but
  is protected by the unconditional arena assert in `alloc`.  Only reachable
  with an already-corrupt object (a healthy non-applicable value is rejected
  by `check-apply`), so it is an amplifier, not a cause.  The unconditional
  cap check from #3 also neutralizes it.

### Ruled out (audited against the prompt's prime suspects — do not spend time here)

- **Module record field offsets:** qmes uses OBARRAY=3/USES=4/EVAL_CLOSURE=6
  (qmes.scm:645,663,673) — exactly `include/mes/constants.h:54-57` and
  `module.c`'s `struct_ref_` calls.  `current-module-variable`,
  `standard-eval-closure-`, `module-make-local-var-x`, `module-variable-`/
  `mv-loop` are line-for-line ports of module.c:59-155 (including the
  `append2` uses-walk).  Verified by side-by-side read.
- **`#:use-module` clause parsing / keyword reading:** the trivial-body
  8-uses module (`v2`) and the 8-uses script header (`dm8`) load fine and
  the imports work — the parse path is exercised and correct.
- **Eval-closure applied with wrong env/arity:** every module in the chain
  gets the *symbol* fast paths (`standard-eval-closure` returns the symbol,
  guile-module.mes:103-106); `apply-proc` mirrors module.c's
  `gc_push_frame`-wrapped apply (qmes.scm:2452, `push-frame!` before the
  nested run).  The r3=vm-apply2 fault signature is the post-corruption
  infinite loop, not an eval-closure call.
- **TSTRUCT/TVECTOR/hash confusion, un-rooted fresh records:** low cells are
  smashed by *host* words (pointers `0x280axxxx`), not by Mes-cell writes;
  gc never ran (`gc-count=0`), so no relocation/rooting could be involved.

---

## 3. Concrete test per hypothesis (summary)

| # | Hypothesis | Test | Expected |
|---|---|---|---|
| 1 | host-heap overflow | `tests/repro/run-hostheap-repro.sh ./qmes.elf tests/repro/use-mescc-preprocess.scm` (and `use-hostheap-cliff.scm`) before/after fix; watch `GCellFree@0x808d3c4` vs `0x2808f000` in a timed core | crash ↔ `SURVIVED` flips; GCellFree stays < ceiling **(pre-fix side already done: it crosses)** |
| 2 | reader chars/radix | `-c '(write (string #\nul #\alarm #\backspace #\tab #\vtab #\page #\return))'` and `-c '(display (list #x10 #b101 #o17))'` A/B vs mes-m2 | byte-identical after fix; today: mangled/misparsed |
| 3 | no tripwires | run repro with tripwires built in | one-line stderr + exit(3), no core; 20e6 boot gates still byte-exact |
| 4 | gc-free apply cycle | after #3, poison a cell type in a debug build and apply it | tripwire exit, not a 70 M-cell runaway |

---

## 4. Recommended fix and instrumentation

### 4.1 The fix (for the fixing agent) — smallest-risk order

The invariant to restore: **no single dispatch step (and no load chain) may
push `GCellFree` past the pair-heap ceiling.**  Three complementary pieces,
smallest first:

1. **Chunked host-heap reset in the reader** — the same pattern already
   shipped for the GC loops in commit 8b7de40 (`gc-tick!`/fixnum-cursor
   trampoline, qmes.scm:89-100): restructure `read-all-forms`/
   `read-forms-loop` (qmes.scm:2400) so that after each *top-level form* the
   host heap is reset to a mark captured at `b-primitive-load` entry.  All
   reader state that must survive the reset is Mes-side (cell indices are
   immediate fixnums; the accumulating forms list should be consed in
   `g-cells` via `qcons` with its head kept in a fixnum global, mirroring
   `gc-scan`/`gc-cc-j`).  This alone removes the single biggest per-step burn
   (the c99-tab read) — but see 2, because 292 MiB were already gone before
   that read.
2. **Stop the floor ratchet across loads:** in `b-primitive-load`, take the
   mark *before* `read-all-forms` and `host-heap-reset!` to it after the
   forms list is built (the forms are g-cells structures; only reader
   transients die), so a nested run's floor no longer sits on top of every
   enclosing read's garbage.  Audit the same for the other `vm-run-nested`
   callers (`apply-proc`, error path).  With 1+2, load-chain high-water
   becomes O(deepest single form), not O(whole graph).
3. **Unconditional tripwires (cheap, from #3):** in `host-heap-reset!` or at
   `vm-dispatch` entry, and at `vm-run-nested` entry, compare the mark
   against a precomputed ceiling (pair-heap base + 0x2000_0000 − slack) and
   `exit 3` with a one-line stderr message; make `alloc-n`'s cap check
   unconditional (one compare per cell — Mes pays the same in `make_cell`).
   These fire never on passing runs, so the byte-exact gates are safe.

Not recommended as the fix: enlarging the pair heap (moves the cliff; MesCC
compiles are bigger than module loading) — acceptable only as extra headroom
after 1–3.  After the crash is gone, fix #2 (reader named chars + `#x/#b/#o`
radix per src/reader.c) or MesCC output will be wrong/non-byte-identical.

Gate: both committed repro scripts print `SURVIVED`; `tools/mescc-smoke.sh`
A/B byte-compare vs `bin/mes-m2`; the standard 20e6 boot gates
(`--help`/`-c`) stay byte-exact; a `MES_ARENA=3e6 --help` run still collects
(gc-count ≥ 1) and matches.

### 4.2 Clean instrumentation (verified non-perturbing)

- **External (zero-perturbation, used throughout this diagnosis):**
  `coredumpctl` cores of native runs; mid-run cores via `kill -6` (note:
  zsh background jobs SIG_IGN QUIT — use `-6`); gdb *with the exact
  `env -i` block of the harness* reproduces byte-identically (extra env vars
  shift the layout and change the failure mode — never probe with a dirty
  environment).  Read `cell-free@0x8089f90`, `gc-count@0x808992c`,
  `GCellFree@0x808d3c4`, r0–r3@`0x80899bc..b0` (raw>>2 = value), g-cells data
  base = `*(*(0x8089f94)−2) & ~7`.
- **Symbol map:** pair `(MovRILabel EAX (Proc N)) … (MovMemLR (GV name) EAX)`
  events from the startup section of `build/qmes/qmes.qfasm` with the
  `mov $imm,%eax … mov %eax,addr` pairs from `objdump -b binary -m i386
  --adjust-vma=0x8048000 --start-address=0x8048058 -D qmes.elf` — gives every
  global's address and every named procedure's entry (script kept in the
  session scratchpad; trivially recreated).
- **In-process, if needed:** only the existing `QMES_DEBUG_ERR` stderr
  pattern; never allocate on the Mes heap or write stdout.  Note the two
  limits hit here: the debug flag's env string itself shifts layout (run
  A/B'd both ways), and the existing alloc-n tripwire guards the wrong
  allocator for this bug — prefer the §4.1(3) host-heap tripwires.

### 4.3 Repro fixtures (committed)

- `tests/repro/use-mescc-preprocess.scm` — minimal one-liner (crashes).
- `tests/repro/modules/test/hostheap-cliff.scm` + `use-hostheap-cliff.scm`
  — self-contained copy of the crashing module, independent of
  `third_party/mes/module` edits (crashes; mes-m2 `SURVIVED`).
- `tests/repro/run-hostheap-repro.sh HOST SCRIPT [MES_DEBUG]` — pinned-env
  loader harness (needs `tools/make-mesroot.sh` once).
