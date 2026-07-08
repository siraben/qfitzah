# qmes full-Mes design: GC, call/cc, the real boot-5 chain, MesCC, x86_64

Status: DESIGN (no implementation). This is the crux-stage design for growing
`bootstrap/qmes.scm` (1728 lines, scaffold-boot-complete) into a **full,
faithful GNU Mes**: one that loads Mes's own `boot-5.scm` module chain to
`(top-main)`, runs MesCC, and reaches the `src/*.c` self-recompilation
fixpoint. It extends `docs/qmes-vm-design.md` (the VM, which is built and
working) and supersedes the P3–P6 sketches in `docs/mes-bootstrap-plan.md`
where they conflict. The sequenced master plan is
`docs/mes-fixpoint-roadmap.md`.

Everything below is grounded in the C spec (`third_party/mes/src/*.c`,
v0.27.1 = f244b14), the Scheme boot chain (`third_party/mes/mes/module/mes/`),
and the current `bootstrap/qmes.scm`. All file:line references were verified
against the tree. Key experimental facts established for this design
(2026-07-07):

- `bin/mes-m2` **does reach `(top-main)`** under boot-5 — but only with a
  *merged* module tree: `%moduledir = $MES_PREFIX/mes/module/` (mes.c:139-141,
  boot-5.scm:139) contains only the `mes/module/` half of the tree; the
  installed layout overlays the top-level `module/` tree (getopt-long, mescc,
  srfi, ice-9, nyacc stubs) into the same directory. With a synthesized merged
  root, `mes-m2 --help` prints usage in 0.45 s, and `-s script` / `-c expr`
  evaluate correctly. Without the merge it dies in `process-use-modules` on
  `(mes getopt-long)`. **The harness must synthesize this merged root** (§5.4).
- The x86_64 MesCC backend requires a host whose numbers are 64-bit:
  `hex2:immediate8` computes `(modulo o #x100000000)` (module/mescc/M1.scm:92-98)
  and `int->bv64` shifts by −32…−56 (module/mescc/as.scm:34-43). The reference
  x86_64 mes is a native M2-Planet `--architecture amd64` build
  (kaem.x86_64:23-26), i.e. `long` = 64 bits. This forces the qmes-64 variant
  of §7.

---

## 1. Fidelity analysis: what boot-5 + the modules actually assume

### 1.1 Verdict

**Exact-index matching is NOT required. Semantic-layout matching IS.**
Nothing in boot-5.scm or the module chain compares SCM values against numeric
cell indices, and nothing observes the obarray intern *order*. What the chain
does observe, exhaustively:

1. **`core:type` tag numbers, via the `<cell:*>` environment bindings.**
   type-0.mes:29-46 defines `char?` etc. as
   `(eq? (core:type x) <cell:char>)` — the constants come from the initial
   environment (symbol.c:182-199 binds `<cell:char>` → `make_number (TCHAR)`),
   so only *internal consistency* between `core:type` and the bindings is
   needed. qmes already uses Mes's exact numeric tags (constants.h:24-44,
   qmes.scm:21-39) and binds them (qmes.scm:542-559). Keep them verbatim —
   they cost nothing and remove a whole class of doubt.
2. **Symbol identity through one obarray.** All type/symbol dispatch is `eq?`
   on interned symbols. Intern order is unobservable: `hashq_` hashes the
   first two *bytes* of the name (hash.c:8-33), never an address or index.
   A moving GC is therefore also invisible to hash tables (§2).
3. **Struct field offsets — hardcoded in Scheme, pinned by the C.** These are
   the real layout contract:
   - variable: value at `struct_ref 3` (variable.c; scm.mes/fluids.mes build
     variables via `make-variable` and store them with `hashq-set!`);
   - hashq table: size at 3, buckets at 4 (hash.c:49-60);
   - **builtin**: `'builtin` at 2, name at 3, arity at 4, function at 5
     (builtins.c:29-64); catch.mes:79-80 reads `(struct-ref f 3)` /
     `(struct-ref f 4)` on builtins for backtraces, and `builtin_p` tests
     `struct_ref (x, 2) == cell_symbol_builtin`;
   - frame: `'frame` at 2, procedure at 3; stack: frames vector at 3
     (stack.c:28-116; used by catch.mes backtraces);
   - module record: `MODULE_OBARRAY 3`, `MODULE_USES 4`,
     `MODULE_EVAL_CLOSURE 6` (constants.h:54-57) — this pins the field order
     of the module record type that guile-module.mes creates in *Scheme*;
     the C reads it in `current_module_variable` (module.c:80-99);
   - srfi-9 records: name at 2, printer at 3, fields at 4, field base 3
     (srfi-9.mes:52-122) — falls out of a faithful `make-struct`;
   - struct printer at index `STRUCT_PRINTER` = 1 (display.c:216).
4. **EOF is a TCHAR with value −1**, not a distinct object: type-0.mes:56,60
   tests `(= (char->integer x) -1)`; posix.c readchar returns −1 at EOF.
5. **`core:car`/`core:cdr` on non-pairs** as raw type introspection:
   module.mes:35 does `core:cdr` on a char (its value word); scm.mes:257
   `core:car` on a bytes object (its length); catch.mes:84-86 `core:car` on
   closures. So `core:car`/`core:cdr` must be the *raw field accessors*,
   unchecked — exactly the C's CAR/CDR builtins.
6. **Environment bindings from `init_symbols`/`mes_environment`**:
   self-bound specials, `%version` (= MES_VERSION "0.27.1"), `%datadir` (from
   open_boot — boot-5.scm:139 derives `%moduledir` from it), `%arch`,
   `%compiler`, `%argv`, the 18 `<cell:*>` numbers, `hash-table-type`
   (symbol.c:176-206), and the `(*closure* . a)` head entry.

### 1.2 Where current qmes diverges (the fidelity refit, edit list D1–D8)

| # | divergence in qmes.scm today | required change | observed by |
|---|---|---|---|
| D1 | builtins are `TFUNC 20` cells `[TFUNC | id | arity]` (qmes.scm:398-403) | **retire TFUNC**: builtins become TSTRUCTs per builtins.c:29-64 — `[builtin-type, 'builtin-printer, 'builtin, name-string, arity-number, id-number]`; `st-apply` tests `TSTRUCT && builtin_p` (eval-apply.c:524); add `builtin?`, `builtin-name`, `builtin-arity`, `builtin-printer` builtins (builtins.c:140-144) | catch.mes backtraces, display of procedures, `builtin?` in scm.mes |
| D2 | `cell-eof` is a TSPECIAL sentinel (qmes.scm:141,461) | EOF value = `(make-char -1)`; `eof-object?`/`char?` then work through type-0.mes unchanged; the reader may keep an internal sentinel that never escapes | type-0.mes:56,60 |
| D3 | hash tables / variables use `cell-symbol-hashq-table` / `cell-symbol-variable` as the struct type slot (qmes.scm:328-346) | build the real type structs (`scm_hash_table_type`, `scm_variable_type`) as in hash.c/variable.c; bind `hash-table-type` in the env (symbol.c:203); both become GC roots (§2.4) | `struct-vtable`, record predicates, display |
| D4 | linear intern list `sym-table` (qmes.scm:221-236) | adopt the C's `g_symbols` = hashq table size 500 (symbol.c:167-172) — **mandatory for performance**: interning is per token read; MesCC reads MBs of source; O(n) scans over ~10 4 symbols would dominate everything | perf only (semantics identical) |
| D5 | no `%datadir`/`%version`/`%arch`/`%compiler`/`%argv`, no `command-line` | transliterate open_boot's g_datadir computation (mes.c:125-172, incl. the `/mes` and `/share/mes` fallbacks and `srcdest`) and mes_environment's bindings; `command-line` from the existing rsc `(command-line)` prim | boot-5.scm:139, mescc.scm:44-47, main.scm |
| D6 | fixed arena/stack sizes (NCELLS=1e6, STACK-SIZE=20000, 2 MiB byte pool) | read `MES_ARENA`, `MES_MAX_ARENA`, `MES_JAM`, `MES_SAFETY`, `MES_STACK`, `MES_MAX_STRING` at startup exactly as gc_init does (gc.c:67-87); allocate `g-cells`/`g-stack`/byte pools with computed sizes before the host-heap mark | harness parity (bootstrap.sh exports MES_ARENA=20e6, MES_STACK=5e6) |
| D7 | reader reads from one slurped `g-input` buffer (qmes.scm:626+) | port-based `readchar`/`peekchar`/`unreadchar` over fd ports + string ports (posix.c), so `primitive-load`/`read`/`read-string` compose; boot file loading becomes `primitive_load`-shaped (§5.2) | module.mes, main.scm, mescc file I/O |
| D8 | ~123 of 161 builtins missing (census: 38 present) | fill per boot-gate tranches (§5.5); names, arities and `core:*` spellings exactly as builtins.c:116-331 | everything |

Everything else in the current qmes — cell tags, TBYTES-indirection string
layout, the VM state set, M0/TBINDING/expand_variable, the g-stack layout —
is already the faithful shape and is untouched by the refit.

---

## 2. Garbage collection

### 2.1 The C collector, precisely (what we transliterate)

Mes's GC (gc.c:307-682) is **not** a classic two-semispace scheme. It is
copy-up-then-slide-back within one arena:

1. `gc_init_news` (gc.c:307-322): "news" space begins at the current
   `g_free`. The arena is allocated with `JAM_SIZE` slack beyond `ARENA_SIZE`
   (gc.c:89-92), and `JAM_SIZE` is re-tuned to 1.5× the live set after each
   collection (gc.c:449-450), so the top of the arena always has room for one
   live-set copy.
2. `gc_` (gc.c:592-644) copies roots in a fixed order: **the fixed-cell
   region `[cell_nil, g_symbol_max)` first, cell by cell, in address order**
   (gc.c:627-629), then `g_symbols`, `g_macros`, `g_ports`,
   `scm_hash_table_type`, `scm_variable_type`, `M0`, `M1`, then the live
   stack `g_stack_array[g_stack..STACK_SIZE)` (gc.c:631-641). R0–R3 are on
   the stack because `gc ()` brackets the whole thing with
   `gc_push_frame`/`gc_pop_frame` (gc.c:661-663).
3. `gc_copy` (gc.c:473-518): forwarding pointer = `TBROKEN_HEART` with
   car → new cell. TSTRUCT/TVECTOR copy header + contiguous body inline;
   TBYTES copies its byte run.
4. `gc_loop` (gc.c:534-580): Cheney scan; car is a pointer for
   {TMACRO, TPAIR, TREF, TBINDING}; cdr is a pointer for {TCLOSURE,
   TCONTINUATION, TKEYWORD, TMACRO, TPAIR, TPORT, TSPECIAL, TSTRING, TSYMBOL,
   TVALUES} (TSTRUCT/TVECTOR bodies handled in gc_copy).
5. `gc_flip` (gc.c:446-471): block-move news back to the arena base,
   adding `-dist` to every pointer field per the same type lists
   (`gc_cellcpy`, gc.c:367-442), then shift the root globals and the live
   stack slots by `-dist`.

**The crucial consequence of step 2 + step 5**: because the fixed cells are
all live, are copied first, and are copied in address order, they land back
at *exactly their original indices* after the flip. `cell_nil`, every
`cell_vm_*`, every `cell_symbol_*` are numerically stable across GC — that is
why the C never rewrites those globals. qmes inherits this for free by
copying its fixed region first in index order, so **none of qmes's ~90
fixed-cell rsc globals need patching at GC time**. (qmes's fixed region is
even cleaner than the C's: since qmes keeps string bytes in a separate pool,
every cell in `[0, g-symbol-max)` is a well-formed 3-word cell — there are no
in-arena byte runs to step over. The C needs the run-init-twice trick at
symbol.c:165-172 for the same property.)

Trigger: `gc_check` — `used + GC_SAFETY >= ARENA_SIZE` → `gc` (gc.c:582-589)
— is called at exactly three VM points: the eval application push
(eval-apply.c:764), the begin loop (898), and the begin_expand loop (928).
`GC_SAFETY` (= ARENA/100, ≈200k cells at 20e6) is the budget for allocation
between safepoints, including everything a single builtin allocates
internally. That contract — **collection happens only at the three
gc_check sites, where all live SCMs are reachable from R0-R3 / the g-stack /
the named globals** — is what makes precise copying GC possible without
scanning host frames, in C and in qmes alike.

### 2.2 qmes rendering

The transliteration is direct because the qmes cell model was designed for
it: an SCM is a fixnum index into `g-cells`, so `dist` is a fixnum delta and
a broken heart is `[TBROKEN-HEART | new-index | 0]`.

```scheme
(define (gc-check)                       ; called from the 3 VM sites only
  (if (>= (+ cell-free GC-SAFETY) ARENA-SIZE) (qgc) cell-unspec))

(define (qgc)
  (push-frame!)                          ; roots R0-R3 onto g-stack (gc.c:661)
  (gc-)                                  ; §2.1 steps 1-5 over g-cells
  (pop-frame!)
  cell-unspec)
```

- `g-news` = `cell-free` at entry; copies allocate by bumping `cell-free`
  (same allocator). The arena vector is allocated as
  `(ARENA-SIZE + JAM-SIZE) * 3` words; `JAM-SIZE` re-tuned at flip per
  gc.c:449-450.
- `gc-copy` / `gc-loop` / `gc-flip` follow gc.c literally with the type
  lists above; `gc-cellcpy`'s TBYTES byte-run special case (gc.c:409-434)
  **drops out entirely** — a qmes TBYTES cell is `[TBYTES | len | pool-off]`
  and its cdr is a pool offset, not a pointer: exclude TBYTES from the cdr
  relocation list. (In the C, the "relocated" TBYTES cdr is immediately
  overwritten by the byte memcpy — cell_bytes starts at the cdr field,
  gc.c:36-40 — so this exclusion is behavior-identical.)
- Roots, in gc_'s exact order, mapped to qmes globals: fixed region
  `[0, g-symbol-max)` → `sym-table`(g_symbols, a hashq table after D4) →
  `g-macros-table` → `g-ports` → `hash-table-type-struct` →
  `variable-type-struct` → `m0` → `m1` → `g-stack[stkp..STACK-SIZE)`.
  New root globals introduced later join this list in one place
  (`builtin-type` struct from D1 is reachable via M0, but add it explicitly —
  the C reaches it the same way; the frame/stack record types are made fresh
  per make_stack call, no root needed).
- `gc` builtin + `gc-stats` + `gc-check` builtins (gc.c:116-150, 582-589,
  builtins.c:176-179) become ordinary registrations calling the above.
- Arena growth (`gc_up_arena`, gc.c:324-355): **not ported initially.** The
  fixpoint harness pins `MES_ARENA = MES_MAX_ARENA = 20e6` (bootstrap.sh.in:
  28-33), which disables doubling in the reference too (gc.c:606-607 requires
  ARENA_SIZE < MAX_ARENA_SIZE). Document the hook; add only if a scaffold
  test demands it (scaffold/boot/memory.scm runs with small MES_ARENA —
  verify its env in test-boot.sh and mirror it).

### 2.3 The byte pool: paired two-space compaction

qmes diverges from Mes here by design (bytes in a separate `g-bytes` string,
TBYTES = offset+len) and the divergence is *good* — it keeps the cell arena
homogeneous and string code byte-addressed. GC extends to it with a paired
copy:

- Two pool strings `g-bytes-a` / `g-bytes-b` of equal size, a current-pool
  global, and `byte-free`.
- When `gc-copy` copies a TBYTES cell, it also copies its byte run into the
  *other* pool at its bump pointer and writes the new offset into the copied
  cell. Sharing is preserved automatically: qmes strings/symbols/keywords
  reference bytes only *through* a TBYTES cell (qmes.scm:118-126), and each
  TBYTES cell is forwarded exactly once. (This is the same indirection
  argument that makes the C's string sharing GC-safe.)
- At flip, swap the pool roles. Old-pool contents die wholesale.
- Pool sizing: default `max(64 MiB, ARENA_SIZE/4 bytes)` each, revisited with
  measurements at the MesCC smoke stage. MAX_STRING (512 KiB, gc.c:65)
  enforced at make-string time as in C. Pool exhaustion sets a
  `gc-pressure` flag checked by `gc-check` (bytes are only reclaimed by a
  full GC, so pool pressure must trigger cell GC).

### 2.4 Interaction with the host-heap-reset safepoint — orthogonal, one new rule

Confirmed orthogonal: the reset reclaims *host* (rsc) cells; all qmes state
lives in `g-cells`/`g-bytes*`/`g-stack`/fixnum globals whose backing storage
is in the rsc *byte* arena, allocated pre-mark, untouched by resets. The GC
runs synchronously inside one VM state (between two dispatches): its host
transients (w32 boxes, loop frames) die at the next dispatch reset; it stores
no host values into globals. Two discipline rules join the §4 audit list of
qmes-vm-design.md:

1. `qgc` may be invoked **only** from `gc-check` at the three transliterated
   sites (and from the `gc` builtin). Never from inside another builtin.
2. No `st-*` state may hold a *cell index* local across a call to a
   procedure that can allocate unboundedly — the C has the same rule
   implicitly (locals are not GC roots); the transliteration inherits it as
   long as states re-derive locals from R1/R2 after gc_check, which the C
   code they mirror already does.

The `qmes-no-reset` bisect switch gains a sibling: `MES_JAM`-style
`qmes-gc-stress` (collect at every gc-check) for flushing root-set bugs early
— cheap and brutal, run it over the whole scaffold ladder in CI once.

### 2.5 Sizing for a full MesCC run

MES_ARENA=20e6 cells × 3 words × 4 B = **240 MB** g-cells; g-stack
(MES_STACK=5e6) = 20 MB; byte pools 2×64-128 MB; reader/input buffers ~16 MB;
total < 600 MB against the rsc runtime's 1 GiB byte arena + 512 MiB cell
arena (already provisioned in the current runtime) inside the 3 GiB i386
space. No substrate change expected; if the pool measurement says otherwise,
bumping the runtime `HeapInit` constants is a one-line generator change and a
committed-runtime regeneration.

---

## 3. call/cc, TVALUES, dynamic-wind, catch

### 3.1 What the core must provide (exact C protocol)

The split is clean and verified: **the core provides raw one-shot
continuation capture/restore + values + stack introspection; scm.mes builds
dynamic-wind and the wrapped call/cc; catch.mes builds exceptions.**
scm.mes:459-574 saves the *core* `call-with-current-continuation` as
`%call/cc`, implements a Scheme-level `dynamic-stack` with
unwind/wind, and **replaces** the bindings in `(initial-module)` via
`hashq-set!` + `make-variable` (scm.mes:571-574). It uses no TVALUES and no
core unwinding.

Core work items, all in the existing VM's terms:

1. **Capture** — the `call_with_current_continuation` label
   (eval-apply.c:996-1005), entered from `st-apply`'s TSYMBOL branch
   (eval-apply.c:580-584). Note the **double snapshot**: capture the stack
   into a fresh TVECTOR, make `x = TCONTINUATION [car = g_continuations++,
   cdr = vector]`, `push-cc! ((proc x) …, r2 = x, c = cc2)`, apply; then in
   `st-cc2` (eval-apply.c:1006-1010) **re-snapshot** the stack (now including
   the frame just pushed) into `r2`'s cdr and vm-return. Transliterate
   literally — the second snapshot is what makes returning *through* the
   capture point work when the continuation is invoked later.
2. **Restore** — st-apply's TCONTINUATION branch (eval-apply.c:543-555):
   copy the vector back to `g-stack[STACK-SIZE−len ..)`, set
   `stkp = STACK-SIZE − len`, `r1 = (cadr r1)` (single value), vm-return.
3. **TVALUES / call-with-values** (eval-apply.c:1013-1021 + `values` builtin,
   lib.c): the two states already stubbed in the VM design (§5.9 there).
4. **stack.c port** — `make-stack`, `stack-length`, `stack-ref`,
   `frame-printer` (stack.c:28-116): frame = TSTRUCT `['frame @2,
   procedure @3]` where procedure comes from
   `g-stack[STACK-SIZE − i*5 + GC_FRAME_PROCEDURE]` — the procedure slot
   st-apply already maintains (qmes.scm's `stack-set! (+ stkp 4)`). Needed by
   catch.mes backtraces (display-backtrace reads them via struct-ref).
5. `g_continuations` counter global; `initial-module` builtin (module.c:40);
   `builtin?`/`closure?` predicates (D1) — all prerequisites of
   scm.mes/catch.mes per the module census (§5.5).

### 3.2 GC interaction

A continuation's captured stack is an ordinary TVECTOR of SCMs — `gc_copy`
handles it like any vector; the slots are relocated by the scan like stack
slots. Nothing special. Size: vectors of `STACK-SIZE − stkp` cells; with
MES_STACK=5e6 a deep capture is theoretically 20 MB, in practice boot's
captures are shallow (catch brackets). No design change; note that arena
sizing already accounts for it via GC_SAFETY headroom at the capture site
(capture allocates the vector *before* the next gc-check — the C has the
identical exposure).

### 3.3 Nesting caveat (inherited from C, not new)

A continuation invoked from a different `eval_apply` nesting level than its
capture (across a `primitive-load` boundary, say) restores the g-stack but
not the host/C recursion — undefined in the C reference too. boot-5's actual
uses (catch/throw within a load; the REPL loop) never cross levels. The
transliteration reproduces the C's nesting exactly (§5.3), so behavior
matches by construction. Do not "fix" this.

---

## 4. Eval re-entry: the nested trampoline and the floor stack

The C core re-enters `eval_apply` from four places — this census is complete
(grep over src/*.c):

| re-entry | site | when |
|---|---|---|
| `primitive_load` | eval-apply.c:1039-1071 (direct `eval_apply ()`) | every `load`/`include`/`mes-use-module` |
| `error` → apply `throw` | core.c:154 | any core error once catch.mes is loaded |
| `current_module_variable` → apply eval-closure | module.c:91-98 | non-standard module eval-closures after guile-module.mes |
| `display_` → apply struct printer | display.c:216-220 | displaying records with closure printers |

In C these ride the C stack. In qmes, a host-recursive call to
`(vm-dispatch)` is *almost* fine — rsc has proper tail calls, the nested run
is internally iterative, and the sentinel protocol (a pushed frame whose R3
slot is `cell-unspec`; dispatch returns R1 when `r3 = cell-unspec`,
eval-apply.c:501-502) is balanced per nesting level exactly as in C. The one
conflict is the host-heap reset: the outer builtin's rsc env frame (e.g.
`primitive-load`'s locals) lives in the host cell arena *above* the boot-time
floor, and nested dispatches would reclaim it.

**Design: make the floor a stack.** A small pre-mark raw-word vector
`floor-stack` + depth counter:

- `(vm-run-nested)` — the only way to re-enter the VM — pushes
  `mark+64` as the new floor, calls `(vm-dispatch)`, pops the floor on
  return. `vm-dispatch`'s safepoint resets to `floor-stack[depth]`.
- Soundness: every host frame belonging to an *outer* activation was
  allocated before the nested mark, hence below the nested floor — protected.
  Everything the nested run allocates above its floor is reclaimed at its own
  dispatch cadence. The pad+64 idiom protects each floor's own w32 box, as
  today.
- Cost: host garbage allocated between an outer floor and a nested push is
  retained for the duration of the nested run — bounded by the outer
  builtin's transients (small) times nesting depth (module include depth,
  ≤ ~10; printer/eval-closure nesting, shallow).

With this, all four re-entries transliterate *literally*:
`primitive-load` is an ordinary builtin that saves/restores the current input
port, reads all forms (host code, one state, no dispatch crossing), conses
`(begin . forms)`, builds the `%program` env, `push-cc!`s a sentinel frame,
sets `r3 = cell-vm-begin-expand`, and calls `(vm-run-nested)`
(eval-apply.c:1039-1071 line for line, including keeping the saved port in
the frame's R2 slot so it survives GC — the C comment at 1064). `error`,
`current_module_variable`, and the display printer hook use the C's `apply`
helper (eval-apply.c:1031-1036) rendered the same way.

The tail-call rule of qmes-vm-design §4.4 is amended: *st-\* procedures and
vm-dispatch may be invoked in tail position, or via `vm-run-nested` from a
builtin — never any other way.*

---

## 5. Loading the real boot-5 chain

### 5.1 Startup transliteration (mes.c main, 211-274)

Replace qmes's current `qmain` boot path with the C's, in order: `init()`
env-var reads (D6) → `open_boot` with the full `%datadir` search
(MES_PREFIX/mes, MES_PREFIX/share/mes, srcdest, cwd; mes.c:125-172) →
`gc_init` arena allocation → `mes_environment (argc, argv)` (all §1.1.6
bindings incl. `%argv` from the rsc `(command-line)` prim) → `mes_builtins`
(the full census) → `init_time` (posix.c; bind `internal-time-units-per-second`
etc. — needed by guile.mes, harmless to determinism since MesCC never calls
them) → `M0`/`M1`/`g_macros` → `read_boot` **through the port layer** (D7):
the boot fd becomes the current input port, `read-input-file-env` reads the
forms → `%program` env → sentinel frame → `r3 = begin-expand` → run.

### 5.2 The port layer (posix.c subset that boot needs)

File-descriptor input ports (`open-input-file` → fd wrapped per posix.c,
current-input-port as TNUMBER fd / TPORT for string ports — qmes's existing
string-port model, qmes.scm:1184-1236, already matches), `readchar` with a
one-char `unreadchar` pushback (`__reader_read_char_buf`, posix.c), output
via fd write with a small flush buffer, `read-string`, `read-char`,
`peek-char`, `write-char`, `eof = -1 char`. File output ports
(`open-output-file` returns fd; mescc writes its `.s` through
`with-output-to-file` built on Scheme-level redirection of `write-byte` —
simple-format.mes/guile.mes pattern — plus the `core:display-port` family
already present).

### 5.3 mes-use-module mechanics (module.mes:25-64) — nothing new needed

`mes-use-module` is a define-macro doing string paths + a `*modules*`
symbol registry + `load` = `primitive-load` of
`%moduledir + "mes/base.mes"` etc. Requirements beyond §4/§5.2:
`string->symbol`, `symbol->string`, `string-join` (Scheme, boot-5.scm:151),
`getenv`, `equal2?` — census items. Double-loading is symbol-`memq`, no
timestamps, fully deterministic.

### 5.4 The merged module root (harness artifact, not a Mes change)

`tools/make-mesroot.sh`: synthesize `build/mesroot/mes/module/` =
`third_party/mes/mes/module/*` overlaid with `third_party/mes/module/*`
(plus, later, `third_party/nyacc/module/nyacc/*` → `.../module/nyacc/`).
Run both `bin/mes-m2` and qmes with `MES_PREFIX=build/mesroot`. Verified
today: with this root the reference reaches top-main, `--help`, `-s`, `-c`.
Never patch files under `third_party/mes` — the chain loads byte-identical
sources on both hosts.

### 5.5 The staged gate ladder to top-main

Gate mechanics: for each rung, a cut file `build/boot-cuts/NN-<mod>.scm` =
boot-5.scm truncated after the Nth `mes-use-module`, ending with a marker
print + `(exit 42)`. Run reference and qmes with `MES_BOOT=<cut>`; gate =
identical exit status + identical stdout/stderr bytes. (boot-5 is loaded via
MES_BOOT path resolution, so cuts work without touching third_party. The
final rungs drop the cut and use the real boot-5.)

Per-rung core requirements (from the verified module census; builtins named
as in builtins.c):

| rung | loads | new core requirements (beyond all previous) |
|---|---|---|
| B0 | boot-5 inline prelude (boot-00..04 layers, boot-5.scm:30-189 head) | `core:hashq-ref` (defined?), `core:display(-port/-error)`, `core:write*`, `core:reverse!`, `core:apply`, `core:eval`, `getenv`, `equal2?`, `string-append`, `%datadir`/`%version`, define-macro (have), `primitive-load` + port layer (§4, §5.2) |
| B1 | type-0.mes (include, boot-5.scm:141) | `core:type` vs `<cell:*>` bindings (have), EOF = char −1 (D2), `char->integer` |
| B2 | module.mes (boot-5.scm:159) | `string->symbol`, `symbol->string`, `memq`, raw `core:cdr` (§1.1.5) |
| B3 | base.mes, quasiquote.mes, let.mes | `vector->list`, `list->vector`, `vector?`; call/cc *symbol* self-binding (have) |
| B4 | scm.mes | **raw call/cc + TCONTINUATION apply (§3.1)**, `initial-module`, `hashq-set!`, `make-variable`, `core:error`/error→throw path, `gensym`, number builtins (`*`,`/`,`<`,`>`,`modulo`), `core:car` on bytes |
| B5 | srfi-13, srfi-14 | string builtins tranche (string.c:291-303: `string-length`? no — Scheme; `substring`? check census: string ops largely Scheme over `string->list`) |
| B6 | fluids.mes | `make-hash-table`, `hashq-get-handle`, `symbol-append` (Scheme), dynamic-wind (Scheme, from B4) |
| B7 | catch.mes | **stack.c port (§3.1.4)**, `builtin?`/`builtin-name`/`builtin-arity` (D1), `closure?` |
| B8 | posix.mes, guile.mes, display.mes, simple-format.mes | `access?`, `open-input-file`, `isatty?`, `read`, `char-ready?`(stub as C), struct-printer display hook (§4), `write-byte`/`read-byte` |
| B9 | srfi-9(-gnu) | `make-struct`/`struct-ref`/`struct-set!`/`struct-length` as builtins (have internally; register), record layouts (§1.1.3) |
| B10 | syntax.mes (syntax-rules via define-macro) | nothing new (macro machinery exists) — a pure differential gate |
| B11 | guile-module.mes | **module.c booted branch**: `current_module_variable` dispatch on MODULE_EVAL_CLOSURE incl. `standard_eval_closure`/`standard_interface_eval_closure` fast paths and the apply re-entry (module.c:59-152), `set-current-module`, `hash-set!`/`hash-ref` (string-keyed hash builtins, hash.c), `list->vector` |
| B12 | srfi-39, (mes main) → **top-main** | `command-line`, `isatty?`, getopt-long (Scheme), `open-input-string` (have), `primitive-eval`(= core:eval alias), REPL bits (repl.scm) |

Checkpoints after B12 (all differential vs `bin/mes-m2`, byte-exact stdout):
`mes --help`; `echo '(display (+ 1 2))' | mes -s /dev/stdin`; `mes -c
'(display %version)'`; scaffold 5x/6x reruns under boot-00/boot-01 piping
(test-boot.sh:30-38 rules) — plus the full existing 80/90 scaffold ladder
staying green throughout.

Ordering rationale: GC (§2) should land **before** B0 — boot-5 to top-main
allocates well past 1e6 cells under the reference (mes-m2 runs GC during
boot; observable via MES_DEBUG=2 dots), and debugging module loading on a
bump arena that silently dies mid-chain wastes time. call/cc (§3) is needed
only at B4.

---

## 6. MesCC end-to-end (i386)

### 6.1 nyacc vendoring

`third_party/nyacc/` = the nyacc release tree, staged into the merged root as
`module/nyacc/...` by make-mesroot.sh. Version: INSTALL:31 pins "1.00.2 or
later; 2.02.2 known to work"; the in-tree `mes/module/nyacc/` contains only
stubs. **Vendor nyacc-1.00.2** (the floor pinned for this release line;
smallest Guile-ism surface) and fall back to 2.02.2 only if 1.00.2 trips on
mes — either is fine for the fixpoint because *both hosts run the same
vendored copy* (reference runs = qmes runs = the committed tree; internal
consistency is what F1 compares). Needed subtrees: `nyacc/lang/c99/`
(parser, cpp, body…), `nyacc/lang/util*`, `nyacc/lex*`, `nyacc/parse*`,
`nyacc/util*`, `nyacc/version*` — imports census: `(nyacc lang c99 parser)`,
`(nyacc lang c99 pprint)` (stubbed in-tree), `(nyacc version)`
(preprocess.scm:28-29, compile.scm:34). Acquisition without Python or C:
`git submodule`/tarball checked in, hash recorded — same policy as
third_party/mes.

### 6.2 Invocation + environment contract

Per mes-bootstrap-plan §5 (still the operative definition of F1/F2/F3), with
these refinements now grounded:

- Entry: `scripts/mescc.scm` under the host mes with the merged root;
  `MES_PREFIX=build/mesroot`, `%version=0.27.1` env, `%arch=x86`,
  `MES_ARENA=20000000 MES_MAX_ARENA=20000000 MES_STACK=5000000`, `LANG=`,
  `MES_DEBUG=0`, pinned cwd, `-D HAVE_CONFIG_H=1 -I include -I build/include`
  with a committed `build/include/mes/config.h` (MES_VERSION "0.27.1").
- `mescc -S` is pure Scheme + file I/O (module/mescc/mescc.scm calls
  `system*` only in assemble/link, lines 202/234/252) — F1 needs **no**
  fork/exec. `primitive-fork`/`core:execl`/`waitpid` (mescc-posix.c) are
  needed only for mescc-driven `-c`/link convenience; F2 links externally
  with mescc-tools invoked by the harness, so these builtins can be deferred
  past F1 (register them in the census anyway for completeness; the rsc
  runtime needs fork/execve/waitpid syscall prims then — the one remaining
  substrate addition, flagged for the F2 stage).
- F1: for every f ∈ mes_SOURCES ∪ {scaffold/hello.c, scaffold/main.c}:
  `.s` under mes-m2 vs under qmes, `cmp`. F2: M1+blood-elf+hex2 (nixpkgs
  mescc-tools, identical invocation both sides, kaem.run:30-165 transcribed)
  → `cmp` binaries. F3: rerun F1 with HOST = the F2 binary itself.
- Determinism controls as in plan §5 (env-scrub table) plus: identical
  merged-root bytes (hash the mesroot), identical nyacc, arena-size
  invariance spot-check (run reference twice at 20e6/40e6, outputs must
  match).
- Divergence workflow: F1 diffs bisect by compiling single functions
  (mescc -S accepts any .c); the boot ladder + `-c expr` differential
  localize interpreter-level drift; `MES_DEBUG` levels agree between hosts.

Wall-time expectation: mes-m2 boots boot-5 in 0.45 s; MesCC+nyacc on real
files is minutes/file under the reference and qmes should land within
2-5× (both are naive-codegen interpreters). F1 files are independent —
**parallelize across processes** in the harness.

---

## 7. x86_64 output

### 7.1 The constraint (verified, §0)

MesCC targeting x86_64 performs host arithmetic on 64-bit values
(`#x100000000` literals, `ash -56`, `quotient/modulo` by 2^32 —
M1.scm:92-98, as.scm:34-43) and reads 64-bit constants from C sources. The
reference x86_64 mes (kaem.x86_64) is a native amd64 M2-Planet build:
`long` = 64 bits. **A 32-bit-value host cannot run mescc --arch=x86_64
faithfully.** An asm.elf ELF64 backend does not help with this — the gap is
in the *interpreter's number semantics*, not in assembly output.

### 7.2 Design: qmes-64 — 64-bit values in a 32-bit process

qmes stays an i386 binary; only its TNUMBER value width changes. Introduce a
build-time variant (same source, one configuration flag rendered by the
build script — the dialect has no #ifdef, so this is a small sed-class
substitution or a generator flag, decided at implementation):

- **Cell layout**: stride 4 words — `[type | car | cdr-lo | cdr-hi]`.
  Accessors gain `cell-cdr-hi`; all *pointer/index* fields (car, cdr as SCM,
  lengths, port ids) remain single-word (indices < 2^27 by arena-size
  arithmetic); only value cells (TNUMBER, TCHAR) and the number paths use the
  pair. Arena cost: 20e6 × 16 B = 320 MB — fits.
- **w64 ops**: a `w64` value = two w32 boxes (lo, hi). Implement
  add/sub (carry via `w32-ult?` compare-after-add), mul (16/32-bit halves;
  the runtime's 32×32 mul feeds schoolbook), divmod (64-bit shift-subtract
  loop in Scheme — acceptable: MesCC divides mainly in dec->hex loops),
  and/or/xor/not (per half), shifts (cross-half), compares. First as a
  prelude library over existing w32 prims; promote hot ones to runtime
  primitives only if profiling demands (that touches
  `generate_rsc_runtime.py`/its Scheme successor + committed runtime, so
  avoid unless needed).
- Reader/printer: number parse/print through w64; `%arch` = "x86_64";
  MES_VERSION unchanged. Semantics = C `long` 64-bit wraparound, matching
  the amd64 reference.
- Everything else (VM, GC, boot chain) is width-agnostic: GC's relocation
  lists operate on the single-word pointer fields; the byte pools and stack
  are unchanged (stack slots hold SCMs).

### 7.3 The x86_64 fixpoint route (minimal added work)

1. Reference: build `bin/mes-m2-64` via kaem.x86_64 (nixpkgs M2-Planet
   `--architecture amd64` + mescc-tools; blood-elf `--64`, hex2/M1 amd64,
   lib/linux/x86_64-mes ELF64 headers) — same pattern as
   tools/build-mes-reference.sh.
2. F1-64: `mescc -S --arch=x86_64 -m 64` over src/*.c under mes-m2-64 vs
   under **qmes-64**; byte-compare.
3. F2-64: link with mescc-tools (`M1 --architecture amd64`, `blood-elf --64`,
   `hex2 --architecture amd64 --base-address 0x1000000`, ELF64 headers from
   lib/linux/x86_64-mes/) — identical invocations both sides.
4. F3-64: the produced ELF64 mes runs **natively** on this x86_64 kernel;
   rerun the F1-64 sweep under it.

**asm.elf needs no 64-bit backend for this.** MesCC emits M1 text; M1/hex2
assemble it on both paths symmetrically (the same trust argument as i386 F2).
An ELF64/REX backend in asm.scm remains a documented optional-hardening item
(it would let the qfitzah ladder emit 64-bit ELFs natively — useful only for
a hypothetical native qmes-64-on-amd64, which the thesis does not require).

---

## 8. Zero Python

Inventory (`tools/*.py`): `build_scheme0.py`, `generate_qfasm.py`,
`generate_qfasm_tests.py`, `generate_rsc_runtime.py`,
`generate_sc1_runtime.py`. All are *generators of committed artifacts*; none
run at build time. Replacement = a dialect program per generator, each gated
by `cmp` against its committed output:

| generator | replacement | notes |
|---|---|---|
| generate_qfasm.py | `tools/gen-qfasm.scm` (rsc dialect) | qfasm.qf1 stays a frozen artifact used once for the asm.elf bootstrap; asm.scm already re-encodes the instruction tables natively, so this is a table-driven text emitter sharing asm.scm's data |
| generate_rsc_runtime.py | `tools/gen-rsc-runtime.scm` | text emitter → rsc-runtime.qf1 byte-identical |
| generate_sc1_runtime.py | `tools/gen-sc1-runtime.scm` | same pattern |
| build_scheme0.py | `tools/build-scheme0.scm` | emits scheme0.qfasm |
| generate_qfasm_tests.py | `tools/gen-qfasm-tests.scm` | fixture emitter |

Dependencies: rsc + asm.elf only — **both exist now**, so this track is
schedulable at any point; it is placed after the i386 fixpoint in the
roadmap purely for focus, and is ideal parallel/filler work. Done = `git
grep -l python tools/ == ∅`, every artifact regenerated byte-identically by
`make regen && git diff --exit-code`, and the .py files deleted in the same
commits (repo policy).

---

## 9. Risks, ranked

1. **F1 long-tail divergences** (top risk, unchanged from the plan):
   reader corner cases, number formatting, macro-expansion order, port
   buffering — each surfaces as a byte diff hours into a sweep. Mitigation:
   the B-gate ladder's byte-exact stdout gates catch most classes before
   MesCC; single-function .c reproducers; parallel per-file sweeps.
2. **GC root-set completeness** — a missed root corrupts rarely and late.
   Mitigation: literal transliteration of gc_'s root order; `qmes-gc-stress`
   over the entire scaffold + boot ladder; MES_DUMP-style arena dumps exist
   in the C for cross-checking a reference collection if desperate.
3. **GC × host-reset × nested-trampoline discipline** — three invariants
   meeting in one VM. Mitigation: the two rules of §2.4, the floor-stack of
   §4, and the bisect switches; all three are mechanically auditable
   (grep-level review rules).
4. **Performance of interpreted nyacc/MesCC under qmes** — could make F1
   iteration painful (not incorrect). Mitigation: D4 obarray hashing;
   measure at F1-hello; per-file parallelism; w32→native-word peepholes in
   rsc only if truly needed (destabilizes rsc fixpoint — last resort).
5. **qmes-64 w64 arithmetic subtleties** (signed div/mod semantics, shift
   counts ≥ 32) — bounded by differential testing against mes-m2-64 on
   arithmetic scaffolds before any MesCC-64 run.
