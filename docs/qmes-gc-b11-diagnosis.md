# qmes GC-under-stress segfault ("B11 bug") — diagnosis

Date: 2026-07-08.  Branch `mes-bootstrap`, clean tree at `df5b427`+.
Status: **root cause identified and experimentally proven** (diagnosis only; no
fix applied).  The collector's tracing is *correct*; the crash is a host
(rsc-runtime) address-space layout bug that only the GC's transient
allocations are big enough to trip.

---

## 1. Failure mode and corrected localization

### 1.1 What was reported
- `MES_ARENA=20000000` full boot: no GC (gc-count=0), byte-exact.  ✔ reproduced.
- `MES_GC_STRESS=1` or `MES_ARENA<=5000000` full boot: SIGSEGV (exit 139).  ✔ reproduced.
- "B0–B10 pass under stress; B11 (guile-module.mes) is the first rung to fail."
  ✘ **NOT reproduced — this localization is stale/wrong for the committed tree.**

### 1.2 Measured ground truth (this tree, this machine)
Running every cut gate with `MES_GC_STRESS=1` (arena 20e6, stack 5e6):

| rung | result |
|------|--------|
| B0–B3 | **PASS** (byte-exact, exit 42) |
| **B4** (`+ (mes scm)`) | **SIGSEGV — first failing rung** |
| B5–B11 | SIGSEGV |

So the failure has *nothing specific to do with guile-module.mes,
set-current-module, or the booted `current-module-variable` path*.  B4 vs B3
differs only by loading `(mes scm)` — a big file that grows the **live set**.
The trigger variable is live-set size, not module machinery.

### 1.3 The proven root cause, in one paragraph

The rsc runtime lays out its host heap arithmetically from the `CodeEnd`
label: pair-cell heap at `[CodeEnd, +0x2000_0000)` (512 MiB), byte heap at
`[+0x2000_0000, +0x6000_0000)` (1 GiB), I/O buffers above, then a single
`brk(CodeEnd+0x6200_0000)` whose **return value is ignored**
(`bootstrap/rsc-runtime.qf1` startup, lines ~23–41).  But the ELF's one LOAD
segment only carries **bss = 0x1000_0000 (256 MiB)** — emitted as the
constant `(X8 1 0 0 0 0 0 0 0)` at **`bootstrap/rsc.scm:882`** — and under
Linux **brk randomization (ASLR)** the kernel places `start_brk` a random
0–32 MiB *above* the end of that segment.  Result: an **unmapped hole**
between BSS end and `[heap]` start, right in the middle of what the runtime
believes is its pair heap:

```
08048000-0808f000  qmes.elf image
0808f000-1808f000  BSS (256 MiB)          <- first 256 MiB of the "512 MiB" pair heap
1808f000-18e97000  *** UNMAPPED HOLE ***  <- ASLR brk gap (random size per run)
18e97000-6a08f000  [heap] (brk'd)         <- rest of pair heap + byte heap + buffers
```

The pair heap is a bump allocator with **no bounds check** (`Cons`,
rsc-runtime.qf1:754–763).  Every rsc-level procedure call conses an argument
list and environment frame there, and every w32 box lives there; the heap is
reclaimed **only** by `host-heap-reset!` at the top of `vm-dispatch`
(qmes.scm:2442).  A garbage collection runs entirely *inside one dispatch*
(`gc-check` → `qgc`), so the transients of a whole collection accumulate:
`gc-copy`/`gc-loop`/`gc-cellcpy`/`gc-copy-bytes` allocate a few conses + w32
boxes **per live cell / per byte copied** — order 400–800 host bytes per live
cell per collection.  Once the boot's live set crosses roughly 300–600 K
cells (first at B4's `(mes scm)`), one collection burns through the 256 MiB
of actually-mapped BSS and `Cons` stores into the hole → SIGSEGV.

### 1.4 The proof

1. **No GC diagnostics fire.**  `QMES_DEBUG_ERR=1` on a crashing B4-stress
   run prints nothing: no `gc-copy bad index`, no `ARENA OVERFLOW`.  No bad
   cell index ever reaches the collector.
2. **Not the machine stack.**  `ulimit -s unlimited` → still crashes
   (tail-calls are compiled to JMPs anyway; rsc.scm header confirms TCO).
3. **Core dump** (B4, stress=1): faulting instruction is the pair-heap
   allocator itself —
   ```
   EIP 0x0808c25b:  mov %eax,(%edx)      ; Cons: store car at GCellFree
   EDX = 0x1808f000                      ; == BSS end == first unmapped byte
   GCellFree(static @0x808d094) = 0x1808f000
   GByteFree = 0x3af76630  == byte-heap base + 318 MiB
                            == exactly g-cells(264 MiB)+g-stack(20 MiB)+pools(32 MiB)
   ```
   i.e. the byte heap holds only the static arenas (healthy); the *pair*
   heap consumed all 256 MiB within a single dispatch and walked off the map.
4. **Live `/proc/<pid>/maps`** shows the hole (table in §1.3) on every
   ASLR-on run; with `setarch i686 -R` the `[heap]` begins at exactly
   `0x1808f000` — no hole, contiguous 512 MiB+ pair heap.
5. **The decisive A/B — `setarch i686 -R` (ASLR off), same binary, same env:**
   - B4, `MES_GC_STRESS=1` → **PASS** (`GATE-B4-OK`, exit 42).
   - B5, `MES_GC_STRESS=1` → **PASS**.
   - B11, `MES_GC_STRESS=1000` (hundreds of collections, including over the
     full guile-module graph) → **PASS** (`GATE-B11-OK`, exit 42).
   - **Full boot, `MES_ARENA=3000000` (the exact reported repro), `--version`**
     → **exit 0, byte-exact `mes (GNU Mes) 0.27.1`, empty stderr**, with
     multiple real threshold-triggered collections (5.5 M cells allocated in
     a 3 M arena forces them).
   (B7–B10 at stress=1 were not run to completion — stress=1 is
   O(steps × live-set) slow, >10 min each — but B4/B5 cover stress=1
   semantics and B11/full-boot cover the largest graphs.)

Conclusion: **when the pair heap is actually mapped, qmes's Cheney GC is
correct over the entire boot-5 module graph, byte-exactly.**  There is no
root-completeness or relocation bug to fix in `gc-copy`/`gc-loop`/`gc-flip`.

### 1.5 Why the misleading symptom pattern
- 20e6 arena, no stress: GC never runs; per-dispatch host transients are a
  few KiB; the bump pointer never leaves the BSS.  Byte-exact.  ✔
- stress / small arena: first collection whose live set exceeds
  ~256 MiB ÷ (per-cell transient) crosses the hole.  The rung where that
  happens depends only on live-set size — B4 today; "B11" in the earlier
  report (plausibly measured on a build with the miscompiled debug
  instrumentation, which the prompt already flags as untrustworthy).
- The hole's size is randomized per run (0–32 MiB), so marginal workloads
  can flake — another reason past per-rung readings disagree.

---

## 2. Ranked suspects

### Suspect 1 — CONFIRMED: pair-heap layout hole (ELF bss 256 MiB + ignored-brk layout vs ASLR brk gap)
- **qmes side:** `bootstrap/rsc.scm:882` emits `(Program Start (X8 1 0 0 0 0 0 0 0) ...)`
  → LOAD segment `memsz = filesz + 0x1000_0000` (`bootstrap/qfasm.qf1:1436`
  `ElfHeader`, mirrored in `bootstrap/asm.scm:459-474`).
  `bootstrap/rsc-runtime.qf1` startup (lines ~23–41) sets
  `GCellFree=CodeEnd`, `GByteFree=CodeEnd+0x2000_0000`, buffers above, then
  `brk(CodeEnd+0x6200_0000)` ignoring the result.  `Cons`
  (rsc-runtime.qf1:754) bumps with no bounds check.
- **Mes side:** mes-m2's C runtime gets its arena from `malloc`/brk via libc
  and never assumes contiguity with the image — no analogue of this bug.
- **Why corruption/SIGSEGV under GC:** only a collection allocates >256 MiB
  of host pairs inside one dispatch (see §1.3 math); the bump pointer enters
  the unmapped ASLR gap at `0x1808f000`.
- **Test (done, positive):** `setarch i686 -R` removes the gap → B4/B5
  stress=1, B11 stress=1000, and full-boot `MES_ARENA=3e6` all pass
  byte-exactly.  **Confirm/refute for the fix:** enlarge the bss constant so
  the LOAD segment backs the whole layout (see §4), rebuild, and re-run the
  same matrix *without* `setarch`.

### Suspect 2 — LATENT (real, next in line): per-collection host transients are O(live set); 512 MiB caps the collectable live set at ~1 M cells
- **qmes side:** `gc-copy`/`gc-copy-body`/`gc-copy-bytes` (qmes.scm:1444-1478),
  `gc-loop` (1482), `gc-cellcpy` (1493), `gc-copy-fixed/-stack` (1530-1535)
  are rsc closures: each iteration conses an arg list + env frame and boxes
  several w32s on the host pair heap, none reclaimed until the next
  `vm-dispatch` reset (design assumption in `docs/qmes-full-design.md`
  §2.4 "its host transients … die at the next dispatch reset" and §2.5
  "512 MiB cell arena (already provisioned)" — the *provisioned* part is
  what Suspect 1 broke, the *sufficient* part is what breaks here).
  Measured bracket: B4's live set overruns 256 MiB but fits in 512 MiB
  → ≈400–800 host bytes per live cell per collection.
- **Why it matters:** at MesCC-fixpoint scale (live sets of several million
  cells at `MES_ARENA=20e6`), one collection needs multiple GiB of pair
  heap.  Overflow past `base+0x2000_0000` lands in the *byte* region —
  i.e. **inside `g-cells` itself: silent corruption, no fault**.
- **Test:** synthetic workload that retains ~1.5–2 M cells (e.g. build a long
  list at the REPL) with `MES_ARENA=6e6` and `MES_GC_STRESS=1`; watch
  `GCellFree` (via a `host-heap-mark` probe or core dump) approach
  `base+0x2000_0000`.  Alternatively add an env-gated canary word at the
  byte-region base and assert it after each `qgc`.
- **Fix direction (later, not for B11):** chunked host-heap reset inside the
  GC loops — drive `gc-loop`/`gc-cellcpy` from a trampoline that keeps
  `scan`/`j` in **fixnum globals** (rsc fixnums are immediate `Small`-tagged
  values, safe across resets; w32 boxes are NOT — never hold one across a
  reset) and does `host-heap-reset!` to a mark taken at `qgc` entry every N
  iterations.  Or a non-allocating primitive loop in the runtime.

### Suspect 3 — HYGIENE: no failure detection anywhere on this path
- `Cons`/`AllocObj` don't bounds-check; startup ignores the `brk` return;
  `alloc-n` (qmes.scm:64) checks `cell-cap` only under `QMES_DEBUG_ERR`.
  Every overflow is a silent corruption or a wild fault with zero
  diagnostics — which is exactly why this bug was mis-localized twice.
- **Test/fix:** env-gated tripwire: compare `GCellFree` against a stored
  limit in `Cons` (or cheaper: after each `qgc`, compare
  `host-heap-mark` against a precomputed ceiling in qmes.scm) and exit(3)
  with a message.  Verify the 20e6 no-GC reference gates stay byte-exact.

### Suspect 4 — RULED OUT (audited + empirically exonerated): GC tracing of the module graph
For the record, the areas the prompt asked to audit were checked against the
C and are **clean**; do not spend time here:
- `gc-car-ptr?` = {TMACRO,TPAIR,TREF,TBINDING} — exactly gc.c:386-389.
- `gc-cdr-ptr-loop?` — exactly gc.c:556-568's list (TSTRUCT/TVECTOR handled
  in `gc-copy` as in C; TBYTES excluded *by design* because qmes keeps a pool
  offset, not inline bytes, in the cdr — the only deliberate divergence, and
  it is consistently excluded in the flip set too).
- `gc-cdr-ptr-flip?` = loop set + TSTRUCT/TVECTOR — matches gc_cellcpy
  (gc.c:393-406) except TBYTES, same design reason.
- Root set (`gc-`, qmes.scm:1536-1552) matches `gc_` (gc.c:627-641):
  fixed region, g-symbols, g-macros, g-ports, hash/variable type structs,
  M0, M1, live stack; qmes adds `builtin-type-struct` (extra root, harmless).
  R0–R3 ride the stack via `push-frame!` exactly like `gc_push_frame`.
- Fixed-region identity relocation is sound: qmes TBYTES is single-cell, and
  no TSTRUCT/TVECTOR exists below `g-symbol-max` (type structs are built
  after the freeze at qmain:2889; `cell-symbol-standard-eval-closure` etc.
  are interned in `init-cells` — *before* the freeze, so the B12 fast-path
  symbol compares stay valid across GC).
- Continuation capture is atomic (make-continuation's raw `stkp` cdr is
  overwritten with the snapshot vector before any gc-check can run),
  mirroring eval-apply.c.
- Struct/vector bodies hold only TREF/TCHAR/TNUMBER entries (`vector-entry`
  = vector.c:81), so linear news scanning relocates module records, obarray
  hash structs, bucket vectors, eval-closures and variables correctly.
- Empirical: B11 with hundreds of collections and the 3 M-arena full boot
  are byte-exact once the address space is contiguous (§1.4.5).

---

## 3. Concrete tests, per suspect (summary)

| # | Suspect | Test | Expected if suspect is the cause |
|---|---------|------|----------------------------------|
| 1 | layout hole | `setarch i686 -R` A/B on B4-stress + 3e6 full boot | crash ↔ pass flips **(already done: it flips)** |
| 1 | layout hole (fix gate) | bump bss to ≥0x6200_0000, rebuild, run B0–B11 `MES_GC_STRESS=1` + full boot at 3e6/5e6 + normal 20e6 gates, ASLR **on** | all pass byte-exact |
| 2 | transient scaling | retain ~2 M live cells, small arena, stress; canary at byte-region base | canary clobbered / silent divergence |
| 3 | no tripwires | env-gated GCellFree ceiling check | clean exit(3)+message instead of SIGSEGV |
| 4 | tracing | (none needed) | already exonerated |

---

## 4. Recommended fix and instrumentation for the fixing agent

### 4.1 The single most likely fix (do this first)

**Back the entire runtime layout with the LOAD segment: change the bss
constant at `bootstrap/rsc.scm:882` from `(X8 1 0 0 0 0 0 0 0)` (0x1000_0000)
to `(X8 6 2 0 0 0 0 0 0)` (0x6200_0000)** — i.e. pair heap 512 MiB + byte
heap 1 GiB + 2×16 MiB buffers, exactly the span the startup code assumes and
`brk`s to.  Then the kernel maps the whole range as segment BSS at exec time;
the ASLR brk gap sits harmlessly *above* the layout and the ignored-brk call
becomes a no-op.  One constant, no runtime/layout logic change, fully
deterministic.  (Total mapping ≈1.6 GiB of the 3 GiB i386 space — the
current binary already brk's to the same top address, so no new pressure.)

Alternative (more invasive, also acceptable): derive the layout base from
`brk(0)`'s return instead of `CodeEnd` in the rsc-runtime startup, and verify
the grow-`brk` return.  Touches `bootstrap/rsc-runtime.qf1` (a committed
generated artifact — regenerate, keep the seed chain reproducible).

Gate after the fix (ASLR **on**, no setarch): `tools/boot-cut-gate.sh` B0–B11
with `MES_GC_STRESS=1`; full boot `--version`/`-c`/`-s` at
`MES_ARENA=3000000` and `5000000` vs the mes-m2 references; the standard
20e6 no-GC gates (must stay byte-exact — this fix cannot perturb them since
it only adds anonymous mapping).

Note: B7–B10 stress=1 runs take >10 min each; run the full ladder once in CI
rather than interactively.

### 4.2 Trustworthy instrumentation (verified not to perturb the no-GC path)

- **Preferred: external, zero-perturbation.**  `setarch i686 -R` A/B runs;
  `/proc/<pid>/maps` snapshots of a live run; `coredumpctl` register/memory
  reads (`GCellFree` static is at the `GCellFree` label; in the current
  binary 0x808d094).  These were sufficient to prove the root cause here and
  cannot perturb anything.
- **In-process, if needed:** reuse the existing `QMES_DEBUG_ERR=1` gating
  pattern (qmes.scm:1444-1451, 64-74): stderr-only, fires never on a passing
  run, so byte-exact gates are unaffected; confirmed to print nothing on
  clean runs in this investigation.  For heap headroom, a `host-heap-mark`
  probe printed to stderr under the same gate at `qgc` entry/exit is safe.
- **Do NOT** add instrumentation that allocates on the *Mes* heap
  (`g-cells`) or writes to stdout, and re-verify the 20e6 byte-exact gates
  after adding any in-process probe — that is the failure mode of the prior,
  untrustworthy instrumentation.

### 4.3 Follow-on (separate change, before MesCC-scale work)
Implement Suspect 2's chunked host-heap reset in the GC loops (or a
non-allocating runtime loop) plus Suspect 3's tripwire, since 512 MiB of
pair heap caps a single collection at roughly ~1 M live cells and overflow
beyond it corrupts `g-cells` silently.
