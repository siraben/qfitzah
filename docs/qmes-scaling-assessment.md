# qmes scaling assessment: the seed-arena ceiling and how to move it

Status: analysis only (no implementation). Grounded in `qfitzah.s`,
`bootstrap/qfasm.qf1` / `tools/generate_qfasm.py`, `build/qmes/qmes.qfasm`
(65,915 instructions, the current qmes), and direct measurements made with the
committed seed binary (peak-RSS experiments, 2026-07-07; the arena is `.bss`,
so untouched pages cost nothing and peak RSS measures arena consumption
directly).

**Headline numbers**

- True per-instruction arena cost today: **~20.8 KB/instr average = ~2,600
  8-byte pairs** (1.37 GB / 65,915), but it is *not a constant* — roughly half
  is a quadratically-growing symbol-table-lookup term.
- True ceiling at the maximum 32-bit arena (~2.6 GiB): **~100k qfasm
  instructions**, not the ~134k a linear extrapolation suggests.
- A full-Mes qmes is an estimated **110–160k instructions**. **It does not fit**
  under the 32-bit seed ceiling — and no amount of tuning the seed's rewriter
  makes the ceiling comfortable, because the seed's cost is intrinsically
  O(assembly *work*), not O(program size).

**Decisive conclusion (revised): escape the seed, don't patch it.** The seed's
term rewriter is the wrong tool for assembling large programs — every fix in
§4(a)–(f) merely pushes a fundamentally O(work), no-GC, 32-bit wall a bit
farther out. The right move is to **stop using the seed to assemble big
programs at all**: write a native i386/x86_64 assembler *in the rsc dialect*,
compile it once through the existing ladder into `asm.elf`, and thereafter
assemble the full qmes, MesCC output, and everything downstream with
`asm.elf` — which is O(program), a few cells/instruction, with a real hash
symbol table. The seed's job shrinks to what it is good at: assembling
scheme0 and the one-time, ~20–40k-instruction bootstrap of `asm.elf` itself
(comfortably under the current ~70k cliff). This is option **(g)** below; it
dominates (a)–(f) and reframes the whole plan (§5–6). The ceiling math in
§1–3 is retained because it is the *proof* that escape is necessary rather
than optional.

---

## 1. The seed's memory model (what a "cell" actually costs)

From `qfitzah.s`:

- **A cell is an 8-byte pair** — `cons` does two `stosl`s and advances the
  bump pointer by 8 (`qfitzah.s:188-201`, `.balign 8` at line 254). There is
  no header, no mark bit, no other allocation type in the arena. Pairs are
  immutable and never freed.
- **The memo cache is fixed-size, not per-term**: `evcache` is 2^21
  direct-mapped 16-byte slots = **32 MiB of separate .bss**
  (`qfitzah.s:509,669-670`). It does not grow with work; it only aliases —
  slot index is `(t>>3) & (2^21-1)`, so the cache wraps every 16 MiB of arena
  and entries are continually evicted by newer allocations. (This matters
  below: eviction is why structurally-repeated but freshly-consed terms never
  hit the memo.)
- Other fixed .bss: `input_buffer` 16 MiB, `atoms` 1 MiB (65,536 × 16 B),
  `outbuf` 4 MiB — ~53 MiB total besides the arena.
- **Allocation sites**: `match` allocates 2 pairs per variable *bound* (even
  on a match that later fails); all-constant patterns allocate nothing.
  `subst` **copies the entire template** on every rule firing (no sharing
  check — unlike `evlis`, which reuses a pair when both children evaluate
  unchanged). So the cost of one rewrite step ≈ 2×(pattern vars) +
  (template pairs), and everything a rule ever builds stays forever.

**Address-space budget.** The seed is a static i386 ELF loaded at
0x08048000 (~128 MiB). User space is 3 GiB. Budget: 3 GiB − 128 MiB (image
base) − 53 MiB (fixed .bss) − ~128–256 MiB (stack: `ev` recursion is ~≤120
B/instruction of chain depth, measured — 65.9k instrs assembles inside the
default 8 MiB, but 300k would need ~40+ MiB, so reserve real room) ≈
**~2.6 GiB practical maximum for the arena `.fill`** (2.8 GiB absolute
best-case). The current `.fill` is 1.5 GiB (`qfitzah.s:255`). Note a `.fill`
bump adds zero bytes to the ELF file (bss is a header field) and zero
semantics — it is the same class of change as the earlier 512 MiB → 1.5 GiB
bump.

## 2. Measured cost per instruction (experiments)

Synthetic programs assembled with the committed seed + `qfasm.qf1`,
peak RSS via `wait4` rusage. Baseline (rules + 10-instr program): 12.5 MB.

| program | marginal cost | interpretation |
|---|---|---|
| N × `Nop` | **10.7 KB/instr** (~1,330 pairs) | pure pass machinery: Pass1 + CodeSize + Pass2, one full `Add32` chain each |
| N × `MovRI r imm32` | 11.4 KB/instr | `LEB`/`HB` byte emission is nearly free (fact tables are all-constant patterns → no env allocation) |
| N × `Label` | 6.6 KB/label (~830 pairs) | CodeSize has no Label-specific rule, so every label pays a full `Add32 pc+0`; Pass1/Pass2 label rules are cheap |
| lookups (calls to the newest label) | +~0.3 KB/instr | depth-1 `Lookup` is negligible |
| lookups (calls to the oldest label) | **~104 B ≈ 13 pairs per Bind-chain step traversed** | 1,000 calls × depth 1,000 = +102 MB, exactly linear in depth |
| 4,000 calls at depth 4,000 | **SIGSEGV at 1.6 GB RSS** | reproduces the production cliff: 4,000 × 4,000 × 104 B ≈ 1.66 GB > 1.5 GiB arena |

Cross-checks against production: the P3b measurement (1.37 GB at 65,915
instructions) and the observed 64–72k cliff both drop out of the model below.

### 2.1 Where the ~2,600 pairs/instruction go (qmes mix)

`qmes.qfasm` composition: 65,915 instructions; 1,676 labels; **9,484
label-referencing instructions** (14.4%) — and critically, **4,778 of the
4,781 `Call`s target the single runtime label `Cons`**, which is bound
earliest in Pass1 and therefore sits at the *bottom* of the newest-first
`(Bind …)` chain, ~1,600 entries deep.

| component | share of 1.37 GB | live at end? |
|---|---|---|
| Nybble arithmetic + rule envs: one `Add32` chain (~430 pairs: 16-var match envs on `Add32`/`A1..A8` + templates) per instruction in **each** of Pass1, CodeSize, Pass2, plus `Sub32`(≈2.5 Add32) on rel32 refs, plus full `Add32 pc+0` per label in CodeSize | **~0.65–0.70 GB (≈50%)** | dead |
| `Lookup` traversals: 13 pairs/step (8 env + 3 template + overhead), no memo help ever — each `(Lookup l sym)` spine pair is freshly `subst`-consed, so every one of the 4,778 `(Call Cons)` re-walks ~1,600 entries; `(GV …)` refs (3,614) walk to wherever their labels sit | **~0.55–0.65 GB (≈45%)** | dead |
| Parsing the 1.45 MB input text (~2–3M pairs), Bind chain, `Size`/`Small` templates | ~30–60 MB (~3%) | input chain + symtab live |
| Emitted `(Bytes …)` output (178 KB ELF ≈ ~2 pairs/byte + spine) | **~5 MB (<0.5%)** | **live** |
| memo cache | 32 MiB fixed | n/a |

**≥95% of arena consumption is dead transients.** A perfect collector would
reduce the working set to input + rules + symbol table + output + in-flight
term ≈ tens of MB. That is the theoretical prize of option (b); the practical
point is that the two dominant terms are *both* fixable at the source, in the
generator, without any collector.

## 3. The real ceiling (recomputed)

Model, calibrated by the experiments and the qmes composition (label refs ≈
0.144·n, labels ≈ 0.0254·n, ~13 pairs per lookup step):

```
arena(n) ≈ B·n + L·n²
  B ≈ 10.5 KB/instr   (pass machinery, current assembler)
  L·n² = lookup term ≈ 0.15 n² bytes   (fit: 0.66 GB at n = 65,915)
```

Validation: predicts 1.36 GB at n = 65,915 (measured 1.37 GB ✓); predicts
exhaustion of the 1.5 GiB arena at **n ≈ 74k** (observed cliff 64–72k ✓,
the spread being instruction-mix variance).

Ceilings (solve for n):

| arena | ceiling, current assembler |
|---|---|
| 1.5 GiB (today) | ~70–74k instrs |
| 2.6 GiB (practical 32-bit max) | **~100k instrs** |
| 2.8 GiB (absolute max) | ~105k instrs |

The quadratic term is why the naive "1.37 GB / 65.9k → 134k at 2.8 GB"
extrapolation is wrong: by 100k instructions the `Lookup` term alone is
~1.5 GB.

### 3.1 Does a full qmes fit?

Estimate of full-Mes qmes size: current qmes is 1,728 lines → 65,915 instrs
(**36–38 instrs/line**, stable across rsc outputs). Remaining C-core surface
to port (gc.c Cheney, call/cc + stack.c, TVALUES, full reader/display, full
module env-closures, remaining ~100 builtins, rest of posix.c) is an
estimated +1,500–2,200 rsc lines → full qmes ≈ **3,300–4,200 lines ≈ 110–160k
instructions**. (MesCC, nyacc, and the whole boot-5 module chain are
*interpreted* — they add zero qfasm instructions; the compiled artifact is
bounded by the C core, which is the saving grace here.)

**Verdict: no.** 110–160k > ~100k even at the maximum 32-bit arena. At
n = 130k the current assembler wants ~4 GB. The gap is a factor of ~1.3–1.6 —
small enough that seed-side constant-factor fixes (§4a) *could* close it for
today's full qmes, large enough that only enlarging `.fill` cannot, and — the
decisive point — the underlying cost is O(assembly work) on a 32-bit, GC-less
rewriter, so the margin any seed patch buys is eroded by every subsequent
growth (x86_64 doubling qmes, richer core). This is why §4(g) escapes the seed
rather than tuning it.

## 4. Fix options, ranked

Ranking criterion: leverage × (1/risk) × thesis-fidelity. Risk is dominated by
whether the trusted 1.7 KiB seed changes; everything is gated by the existing
byte-identical checks (qfasm differential fixtures, sc1 + rsc fixpoints,
qmes 80/90 boot-ladder differential), which make output regressions loud.

**Ranking summary (revised):** (g) native assembler ≫ (a) leaner seed
assembler > (c) staged runs > (b) seed GC > (e) shrink qmes; (d) folded into
(c); (f) rejected. (g) is not one more constant-factor push against the wall —
it removes the wall, and it is the natural next rung of the ladder's own
philosophy ("each rung is a real processor that runs the rung above it").
(a)/(c) survive only as *insurance for (g)'s one-time bootstrap*, not as the
endgame mechanism.

### (g) Native assembler in the rsc dialect. **Recommended. Ranked #1 — dominant.**

The seed assembler is O(assembly work): ~2,600 pairs/instruction, a quadratic
`Lookup`, no GC, 32-bit address space. A native assembler is O(program): it
reads the program once, builds a **hash** symbol table (O(1) lookup, not a
linear `(Bind …)` rewrite), and emits bytes in two passes — a handful of cells
per instruction, no per-instruction transient explosion. The whole ceiling
analysis of §1–3 simply does not apply to it.

**What it is.** `bootstrap/asm.scm`, an rsc-subset program that consumes the
*same* `(Assemble (Program entry bss code))` s-expression rsc already emits
(so rsc's output feeds it unchanged), and produces the identical ELF bytes the
seed+`qfasm.qf1` produce. It needs exactly what `qfasm.qf1` encodes, now as
ordinary Scheme:

- a reader for the input s-expr (reuse the rsc reader already in the runtime);
- the instruction-encoding table — a direct transliteration of
  `tools/generate_qfasm.py`'s `INSTRUCTIONS`/ModRM/opcode logic (~60 forms), as
  a `case` dispatch computing size and bytes;
- a two-pass driver: pass 1 assigns label addresses into a hash table (labels
  are arbitrary terms → hash on a structural key), pass 2 emits with resolved
  operands; native 32-bit integer arithmetic replaces the nybble-list
  `Add32`/`Sub32`/`LEB` machinery entirely (this is where the ~2,600× cost
  came from — gone);
- ELF header emission and byte output to a buffer, then `sys-write`.

**Is `asm.elf` small enough to bootstrap through the seed?** Yes, with margin.
Reference points from the ladder: sc1 (a *compiler*) is ~25k instrs, rsc ~42k,
qmes 65.9k. An assembler is structurally simpler than sc1 — no closures,
lexical addressing, or codegen — but carries a chunky encoding table. Estimate
**~500–1,000 rsc lines → ~20–40k instructions**, well under the current ~70k
seed cliff. So the bootstrap chain is:
`rsc → asm.qfasm (~20–40k instrs) → [seed + qfasm.qf1] → asm.elf`. The seed
only ever assembles this once (and scheme0), both small. If `asm.elf` happens
to land near the cliff, §4(a)'s A1+A2 diet (still cheap, still zero-seed-risk)
buys the headroom for that single bootstrap — the *only* remaining use of the
diet.

**Does rsc's runtime suffice, or does `asm.elf` need a GC?** It suffices, with
**no GC**, for programs far larger than a full qmes. The runtime
(`generate_rsc_runtime.py:141-177`) gives 512 MiB of cells + 1 GiB of bytes +
16 MiB read buffer, `brk`-grown, in a native i386 process. A batch assembler's
*live* memory is O(program), not O(work): parse the program into the arena
(300k instrs × ~5–10 cells × 8 B ≈ 15–25 MB), a hash symbol table (a few
thousand labels), and the output byte stream (~1 MB) — a few tens of MB total,
inside 512 MiB with room for millions of instructions. No transient blow-up
exists to collect: native integer arithmetic allocates nothing, and the hash
table is fixed-size. (If a target ever exceeds ~4M instructions, bump the
arena constant or slurp+re-parse the input twice from the 16 MiB read buffer
instead of building a full AST — the safepoint `host-heap-mark`/`reset!`
already exists if a streaming discipline is wanted. Neither is needed for the
Mes endgame.)

**Trust and validation** (this is what makes (g) safe despite adding a native
tool below the big builds):

- **Differential against the seed.** `asm.elf` must produce byte-identical
  output to `[seed + qfasm.qf1]` on *everything both can handle*: the qfasm
  differential fixtures, scheme0, sc1, rsc, and today's 65.9k-instr qmes. That
  is a broad, already-committed equivalence oracle — any encoding bug is loud.
- **Self-fixpoint.** `asm.elf` assembling its own `asm.qfasm` must reproduce
  `asm.elf` byte-for-byte — a genuine fixpoint that validates the native
  assembler the same way sc1 and rsc validate themselves.
- **Thesis fidelity is *improved*, not spent.** The seed stays the sole
  hand-audited 1.7 KiB root, frozen. `asm.elf` is a *derived* artifact,
  compiled by the already-fixpointed rsc — exactly the ladder's intended
  shape (sophistication migrates upward; the root stays minimal). Nothing new
  becomes "trusted" in the audit sense.

**Effort:** ~3–6 focused days for the i386 assembler (mechanical encoding
transliteration + hash table + two-pass driver + ELF emit + the two
validation gates). **Seed risk: zero.** New ceiling: effectively unbounded for
the Mes program sizes in play (bounded by 512 MiB / a few-cells-per-instr ≈
low-millions of instructions).

**x86_64 output** (expanded end-goal). Add a 64-bit backend to `asm.elf`: a
parallel instruction-encoding table (REX prefixes, 64-bit ModRM/SIB, the
x86_64 register file) and ELF64 emission (64-byte header + program headers).
The host stays a 32-bit rsc/qmes process — an assembler does not execute what
it emits, so target word size is just which byte table it selects; this is
*cross-assembly*, clean and isolated. Cost: ~+400–800 rsc lines, gated by a
new differential (assemble a small program to x86_64, compare against
`as`/an independent model, or against Mes's `M1`+`hex2` x86_64 path). This is
the correct place for 64-bit support — a 64-bit *seed* (§4f) is rejected, but
a 64-bit *backend in the native assembler* is cheap and does not touch the
trusted root. It pairs with Mes's own `module/mescc/x86_64` + `kaem.x86_64`
so the MesCC fixpoint can be run for both architectures.

### (a) Leaner assembler — generator-only. **Ranked #2 (now: insurance for (g)'s bootstrap).**

Three independent cuts, all in `tools/generate_qfasm.py` (+ one in `rsc.scm`),
none touching the seed:

- **A1 — delete the CodeSize pass.** Pass1 already threads the pc across the
  whole chain and throws it away (`(Pass1 End pc sym) → sym`). Return both:
  `(Pass1 End pc sym) → (P1Done sym pc)`, destructure in `Asm2`. Kills one
  full `Add32` per instruction *and* the pathological `Add32 pc+0` per label.
  Saves ~3.5 KB/instr (~30%+ of the base term). Effort: hours. Output bytes:
  identical by construction.
- **A2 — carry-short-circuit pc advance.** ~92% of pc updates add 1–6 to the
  low nybble without carrying past digit 1. Add an `(AddSm pc d)` family that
  consumes one digit and only falls into wider propagation on carry
  (fact-table `AD` already exists). One add drops from ~430 pairs (16-var
  envs across an 8-step chain) to ~60. Keep full `Add32/Sub32` for label
  arithmetic. Base cost B: 10.5 KB → **~2 KB/instr**. Effort: ~1 day
  (+ fixtures).
- **A3 — restructure `Lookup`.** The quadratic term. Two grades:
  - **A3-lite: shard the symbol table by label head shape.** Pass1 keeps 5–6
    sub-chains keyed on the label's head (`Lb` / `Lit` / `LitB` / `Proc` /
    `GV` / bare runtime atom); `Lookup` dispatches into the matching chain.
    Max depth falls from 1,676 to ≤~470, and the killer case — 4,778
    `(Call Cons)` — lands in a ~40-entry runtime-atom chain. Cuts the
    quadratic coefficient ~4–8×. Generator-only, ~1 day.
  - **A3-trie: digit-decomposed labels.** Have rsc emit numeric labels with
    separated digit atoms (`(Lb 4 6 0)` instead of `(Lb 460)` — the seed
    cannot decompose an opaque atom, so the *emitter* must) and give qfasm a
    10-ary trie: O(digits) lookup, O(digits) path-copy insert. Kills the
    quadratic outright. Touches rsc label emission + generator; addresses
    and output bytes unchanged; ~2–4 days.

  (Why the memo can't do this for us: memoization is by *pointer*, and every
  `(Lookup l sym)` spine pair is freshly allocated by `subst`, so
  structurally-identical lookups never hit. This is inherent to the rewrite
  model, not a cache-tuning problem.)

New ceilings (with `.fill` at 2.6 GiB):

| package | per-instr model | ceiling |
|---|---|---|
| A1 only | B≈7.1 KB, L unchanged | ~109k |
| A1+A2 | B≈2 KB, L unchanged | ~124k (and **~96k on the existing 1.5 GiB arena**) |
| A1+A2+A3-lite | B≈2 KB, L÷4 | **~235k** |
| A1+A2+A3-trie | B≈2 KB, L≈0 | ~1M+ (new binders: input_buffer text ~22 B/instr caps ~700k; bump if ever relevant) |

Risk: **zero to the seed**; low overall (each step must keep the differential
fixtures and both fixpoints byte-identical — for A1/A2/A3 the emitted ELF
bytes are unchanged by construction, only the rewrite work changes).

**Revised role:** (a) is no longer the endgame mechanism — (g) is. Its lasting
value is narrower and real: **A1+A2 guarantee that `asm.elf`'s own one-time
bootstrap fits under the seed cliff** even if the native assembler lands near
40k instructions, and they make the seed pleasant for scheme0 and future small
seed-side assembly. A3 (the anti-quadratic work) is *unnecessary* once (g) is
in place, because the big programs never touch the seed again. Do A1+A2 if and
only if the `asm.elf` bootstrap measures tight; skip A3 entirely.

### (c) Staged assembly across seed invocations. Ranked #3 (reserve; likely unneeded).

The rewrite model cannot express "free Pass1's transients before Pass2"
within one evaluation — but the *build script* can: the ladder is already
`cat rules prog | seed`, and each seed process is a fresh arena.

- Run 1: evaluate `(Pass1 code (Small 0) Empty)` as a top-level line; the seed
  prints its normal form — the `(Bind …)` chain — plus the code size.
- Run 2: fresh seed; the harness wraps run-1 output back in with
  `printf '(Rule (SymTab) ' ; cat pass1.out ; printf ')'` (still sh+cat-class
  tooling) and runs Pass2 with the pre-built table threaded as an argument.

This halves-ish per-run cost (×~1.7 ceiling) and, extended per-segment
(run Pass2 over instruction chunks at known starting pcs, `cat` the raw byte
outputs — qfasm output is a plain byte stream, so **no linker is needed**,
which also disposes of option (d) below), it bounds the Pass2 run
arbitrarily. But it does **not** fix the `Lookup` quadratic (the table must
still be traversed per reference in run 2 — and note the tempting
"symbol-table-as-rules" variant, one `(Rule (Addr l) pc)` per label, is
blocked: the seed prints one term per line and cannot emit label atoms as
text through the `Bytes` path, and a `(SymTab)`-expanding rule would be
`subst`-copied per firing). Use it only if (a) falls short. Effort: ~1 day of
generator + `tools/build-qmes.sh` work. Seed risk: zero.

### (b) Seed garbage collection. Ranked #4 — superseded by (g).

Feasibility, honestly assessed:

- **Cheney is out.** `ev` holds live term pointers in registers pushed at
  arbitrary depths of the native stack; roots are only *conservatively*
  enumerable (scan the machine stack for 8-aligned values inside the arena).
  Conservative roots cannot be relocated → no copying collector without a
  rewrite of the evaluator's recursion into an explicit, precisely-typed
  stack. That rewrite is bigger than the collector.
- **Conservative mark-sweep is feasible.** Non-moving; side bitmap (1 bit per
  pair: 44 MB .bss at a 2.8 GiB arena); free-list threaded through dead
  cells; roots = machine stack + registers + `rules` + the per-atom rule
  buckets (`atoms[i]+8`). The memo cache is handled in O(1): bump `ev_gen` —
  the cache is already documented as "can only affect speed, never results",
  and the invalidation machinery exists (`add_rule` does exactly this). A
  refinement (sweep entries whose key/value died, keep the rest) preserves
  performance across collections.
- Cost: ~250–400 bytes of code in the **trusted root** (+15–25% of the thing
  the whole project promises stays hand-auditable), plus the risk class of GC
  bugs in the layer beneath every fixpoint check. Post-GC memo loss triggers
  an O(program) re-walk (allocation-free, thanks to `evlis` sharing), so
  infrequent collections are time-cheap.
- Payoff: arena → O(live) ≈ tens of MB; ceiling effectively unbounded
  (500k+ instrs). Effort: 3–6 days including soak testing.

Rank rationale: it is the *most powerful seed-side* fix and the *only* one that
changes the trusted root — which is exactly why (g) beats it. (g) achieves the
same "O(live), unbounded ceiling" outcome by moving the work into a *derived*
native tool, leaving the audited seed untouched. There is no scenario where
(b)'s cost (250–400 bytes in the trusted root + GC-bug risk beneath every
fixpoint) is worth paying once (g) exists. Retire it from the plan; keep this
analysis only as the record of why the seed itself is not worth growing.

### (d) Segmented assembly + linker. Collapsed into (c).

qfasm emits one ELF per `Assemble` and there is no linker; building one would
be a new trusted-adjacent component. But segmentation *without* a linker is
exactly the (c) extension: resolve all addresses globally in a cheap Pass1
run, then emit byte segments at known pcs and concatenate. No separate option.

### (e) Shrink qmes / tighter rsc codegen. Bounded; not the lever.

The biggest single win is visible in the data: 4,778 `Call Cons` — inlining
cons allocation (~4 instrs) would *add* size; a calling-convention tweak or
peepholes might cut total instructions 15–25%. But it destabilizes rsc's own
fixpoint for a one-time constant, and 160k × 0.75 = 120k still exceeds the
100k ceiling. Worth doing opportunistically later, never as the fix.

### (f) 64-bit seed. Rejected.

Rewriting the trusted root in another ISA voids the audit story and the
"1.7 KiB i386 seed" thesis; every downstream artifact (qfasm's emitter,
scheme0/sc1/rsc/qmes binaries, mes-m2 parity) is i386; and it is unnecessary
given (a). PAE does not extend a 32-bit process's address space; there is no
cheap variant.

## 5. Reachability verdict

**The full `src/*.c` MesCC fixpoint — on both i386 and x86_64 — is reachable,
and the enabling move is (g): escape the seed via a native assembler.** The
seed ceiling is real (§1–3) but it is a property of the *seed as assembler*,
not of the architecture. Once large programs are assembled by a native,
O(program) tool, the ceiling that bounds the endgame simply ceases to exist.

- **The endgame is bounded by the C core, and that fits `asm.elf` trivially.**
  boot-5.scm, the whole module chain, nyacc, and MesCC are all *interpreted*
  by qmes — they add zero assembled instructions. The only thing that must be
  assembled is qmes itself (~110–160k instrs), plus MesCC's *output* `.s`/ELF
  during the fixpoint (produced by MesCC and, for the qfitzah path's own
  binaries, assembled by mescc-tools' `M1`/`hex2`, not by qfitzah at all). A
  native assembler eats 110–160k instructions in tens of MB; there is nothing
  left to block on.
- **Why not just do the seed diet (a)?** It reaches ~235k at a 2.6 GiB arena —
  which *would* cover a full qmes with ~1.5× margin. But it is a one-shot
  cushion against a wall that keeps its shape: it is O(work), it stays 32-bit,
  it has no GC, and every future growth (x86_64 backend doubling qmes, a
  larger reader/printer, richer MesCC support code compiled in) eats the
  margin. (g) removes the wall instead of moving it, for comparable effort
  (~3–6 days vs. ~2–3 for A1+A2+A3-lite) and with *strictly better* thesis
  fidelity (the seed stays frozen; the new capability is a fixpoint-validated
  derived artifact).
- **x86_64** is reachable through the same tool: a 64-bit backend in `asm.elf`
  (§4g) plus Mes's existing `module/mescc/x86_64` + `kaem.x86_64`. The host
  interpreter stays 32-bit; only the emitted byte tables and ELF header
  change. A 64-bit seed is not needed and is rejected.
- **Zero-Python** falls out of the same program: the native assembler
  *subsumes* `generate_qfasm.py` (the encoding logic becomes `asm.scm`'s
  tables — there are no `qfasm.qf1` rules to generate once big builds bypass
  the seed), and the remaining generators (`generate_rsc_runtime.py`,
  `generate_sc1_runtime.py`, `build_scheme0.py`, `generate_qfasm_tests.py`)
  are text emitters that port to rsc/Scheme programs producing byte-identical
  `.qf1`/`.qfasm` output. `qfasm.qf1` itself is kept as a *frozen committed
  artifact* for the seed's one-time `asm.elf` bootstrap (regenerable by a small
  dialect program to honor the no-Python rule).

**Smaller end-to-end fixpoint worth targeting first? Yes — but as a
stepping-stone under (g), not as the final claim.** The natural first
demonstration is `mescc -S scaffold/hello.c` byte-identical to the mes-m2
reference (plan F1-hello), which needs a qmes with call/cc + GC + TVALUES +
full reader/printer (~95–110k instrs). Under the *old* plan this forced the
assembler diet just to fit; under (g) it fits `asm.elf` with vast headroom and
is simply the first rung of the full sweep. It remains valuable as the
smallest artifact that exercises the entire thesis (seed → rewriting → Scheme
→ Mes → MesCC-output parity, no C below), so target it as milestone 1 of the
post-`asm.elf` sequence — but the committed goal is the full `src/*.c` F1/F2/F3
fixpoint on i386 and x86_64.

## 6. Recommended path

Staged so each step is bootstrapped by the previous (the ladder's own
discipline), with a byte-identical gate at every rung.

1. **Build the native i386 assembler `bootstrap/asm.scm`** in the rsc subset:
   transliterate `generate_qfasm.py`'s encoding tables into a `case` encoder,
   add a hash symbol table + two-pass driver + ELF emit, reading the existing
   `(Assemble (Program …))` s-expr. Compile it with rsc → `asm.qfasm`
   (~20–40k instrs), and assemble that **once** with `[seed + qfasm.qf1]` →
   `asm.elf`. **Only if that bootstrap measures tight against the ~70k cliff,
   apply A1+A2** (§4a) to `generate_qfasm.py` first — nothing else from (a)–(f)
   is needed.
   Gate: `asm.elf` byte-identical to `[seed + qfasm.qf1]` on the qfasm
   differential fixtures, scheme0, sc1, rsc, and today's qmes; plus the
   `asm.elf` self-fixpoint (it reassembles its own `asm.qfasm` to itself).
2. **Switch the heavy build to `asm.elf`.** Repoint `tools/build-qmes.sh`'s
   final step (and any large assembly) from the seed to `asm.elf`. The arena
   ceiling is now gone; resume the qmes port (P3c/P4: define-macro activation,
   full ports, GC/Cheney, call/cc, TVALUES, remaining builtins, full
   reader/printer) without rationing instructions. Milestone: boot-5.scm to
   `top-main`, then `mescc -S scaffold/hello.c` == reference (F1-hello).
3. **Full i386 fixpoint.** F1 over all of `src/*.c`, F2 link+cmp, F3
   self-recompilation, per `docs/mes-bootstrap-plan.md` §5.
4. **x86_64 backend in `asm.elf`** (§4g) + Mes's `module/mescc/x86_64` +
   `kaem.x86_64`; gate with an x86_64 assembly differential, then run the
   F1/F2/F3 sweep for x86_64 as well.
5. **Zero-Python.** Port `generate_rsc_runtime.py` / `generate_sc1_runtime.py`
   / `build_scheme0.py` / `generate_qfasm_tests.py` (and a regenerator for the
   frozen `qfasm.qf1`) to rsc/Scheme emitters, each gated by producing its
   committed output byte-for-byte. This also serves as broad end-to-end
   exercise of the native tooling.

Seed's residual role after step 2: assemble scheme0 and the one-time
`asm.elf` bootstrap — both small, both permanently under its comfortable
regime. The 1.7 KiB trusted root never changes.

Secondary ceilings, now mostly moot (they were seed limits; `asm.elf` has its
own, all generous): `asm.elf` arena 512 MiB cells / 1 GiB bytes holds
millions of instructions; if ever needed, bump the runtime constant or use the
existing `host-heap-mark`/`reset!` safepoint to stream. On the seed side, only
the `asm.elf` bootstrap and scheme0 matter, and both sit far under every seed
limit (arena, 8 MiB stack, 16 MiB input buffer, 65,536-entry atom table).
