# The Mes fixpoint roadmap (master plan)

This is the single sequenced north-star plan from today's state to the full
`src/*.c` MesCC self-recompilation fixpoint on i386 **and** x86_64, with zero
Python. It supersedes the staging sections of `docs/mes-bootstrap-plan.md`
(§4/§7) and `docs/qmes-scaling-assessment.md` (§6) as the ordering authority;
those documents remain the reference for the F1/F2/F3 definitions (§5 of the
plan) and the asm.elf rationale. The technical design behind every stage here
is `docs/qmes-full-design.md` (cited as FD §n).

**Where we start (all DONE, verified):** the seed→rsc ladder with byte-exact
fixpoints; `asm.elf` native assembler (seed ceiling gone; qmes builds via
asm.elf); `bootstrap/qmes.scm` = Mes-core VM passing 80/90 of the scaffold
boot ladder against `bin/mes-m2`; the reference `bin/mes-m2` reaches
`(top-main)` under boot-5 with a merged module root in 0.45 s.

Legend — Mode: **[O]** Opus-implementable from the written design;
**[F]** needs Fable-level design iteration first; **[O/F]** Opus with a
Fable review gate. Every stage lands committed with `tests/run.sh` green and
the prior scaffold differential intact; old code is deleted in the same
commit that replaces it.

---

## Track A — full qmes to top-main

### S0. Harness: merged root, references, gate generator — [O], no deps
- `tools/make-mesroot.sh`: merged `build/mesroot` (mes/module ∪ module ∪
  later nyacc) (FD §5.4). Never patches third_party.
- Reference checks: mes-m2 `--help` / `-s` / `-c` outputs recorded;
  boot-5 cut-file generator for the B-gates (FD §5.5); sha256 manifest.
- Gate: mes-m2 reaches top-main from `build/mesroot`; cut files run.
- Risk: low. Effort: ~0.5 d.

### S1. Fidelity refit D1–D8 — [O], needs S0
The eight divergence fixes of FD §1.2: TSTRUCT builtins (+`builtin?` family),
EOF = char −1, real hash-table/variable type structs, hashq obarray
(g_symbols, size 500), `%datadir`/`%version`/`%arch`/`%argv`/`command-line` +
full open_boot search, env-driven arena/stack sizes, port-based reader
refactor + `primitive-load` + the **nested trampoline / floor stack**
(FD §4 — the one architecturally new mechanism; its design is fixed, but
review its audit rules at PR time), builtin tranche B0–B2.
- Gate: existing 80/90 scaffold ladder unchanged; B0–B2 cut gates pass
  (boot-5 head + type-0 + module.mes); `mes -c`-style smoke via MES_BOOT.
- Risk: medium (floor stack discipline). Effort: 2–4 d.

### S2. Garbage collection — [O/F], needs S1
FD §2 in full: copy-up-slide-back collector over g-cells, paired two-space
byte pools, root order per gc.c:626-643, three gc_check sites, MES_JAM/
MES_SAFETY/MES_MAX_STRING, `gc`/`gc-stats`/`gc-check` builtins,
`qmes-gc-stress` switch.
- Gate: scaffold gc.scm + memory.scm match mes-m2; whole ladder green under
  `qmes-gc-stress`; boot-5 head (B0–B2) with a deliberately tiny MES_ARENA
  survives repeated collections.
- Risk: med-high (root completeness). Effort: 2–4 d. Fable review of the
  root-set mapping before merge.

### S3. call/cc + TVALUES + stack.c — [O], needs S2
FD §3: double-snapshot capture, TCONTINUATION restore, call-with-values,
values, make-stack/stack-ref/stack-length, g_continuations.
- Gate: scaffold call-cc.scm matches; remaining 4x/5x/6x scaffold rungs
  (boot-00/boot-01 piped per test-boot.sh) all match — the scaffold ladder
  closes at 90/90 (minus any rungs where the reference itself segfaults,
  documented).
- Risk: low-medium (protocol is small and exactly specified). Effort: 1–2 d.

### S4. The boot-5 module ladder B3→B12 — [O], needs S3
Walk the gate table of FD §5.5: scm.mes (B4) through guile-module.mes (B11)
to `(mes main)`/top-main (B12), registering each rung's builtin tranche
(census in FD §5.5; full delta table from builtins.c in the census report).
Includes the module.c booted-branch port at B11.
- Gate per rung: byte-exact stdout/stderr + exit status vs mes-m2 on the cut
  file. Final gates: `--help`, `-s`, `-c` byte-parity; 80/90→full ladder
  still green.
- Risk: medium — this is where semantic drift surfaces; the per-rung gates
  keep reproducers small. Effort: 3–6 d.

## Track B — MesCC and the i386 fixpoint

### S5. Vendor nyacc + MesCC smoke (F1-hello) — [O], needs S4
nyacc-1.00.2 into `third_party/nyacc` (FD §6.1), mesroot overlay, config.h,
env contract (FD §6.2); `mescc -S scaffold/hello.c` + `scaffold/main.c`
byte-identical under qmes vs mes-m2. Measure wall time; decide whether any
perf work is warranted before the sweep.
- Gate: F1-hello `cmp` clean, both hosts, plus arena-invariance spot check.
- Risk: medium (first contact with nyacc-scale interpretation). Effort:
  2–4 d.

### S6. F1 sweep → F2 link → F3 fixpoint (i386) — [O], needs S5
Per mes-bootstrap-plan §5, parallel per-file: all mes_SOURCES `.s`
byte-match (F1); M1/blood-elf/hex2 link, binaries `cmp` (F2); rerun the
sweep hosted on the F2 binary (F3). Needs fork/exec/waitpid rsc runtime
prims only if we let mescc drive the link itself — harness-driven linking
avoids even that (FD §6.2).
- Gate: `make fixpoint` = F1+F2+F3 clean; hashes committed.
- Risk: **high** (long-tail divergence hunting; compute-bound iterations).
  Effort: 2–5 d + compute; the stage that most benefits from parallel
  per-file harnessing.

**★ This is the working fixpoint — the thesis result on i386.**

## Track C — x86_64

### S7. qmes-64 variant — [F design done → O], needs S2 (mergeable pre-S6)
FD §7.2: 4-word cells, w64 value ops as a prelude library, 64-bit
reader/printer, `%arch=x86_64`. Differential-test w64 arithmetic against
mes-m2-64 on arithmetic scaffolds first.
- Gate: full scaffold ladder + boot-5 to top-main under qmes-64 vs
  mes-m2-64 (built in S8; the two stages interleave).
- Risk: medium (64-bit div/shift corners). Effort: 2–3 d.

### S8. x86_64 reference + F1/F2/F3-64 — [O], needs S6 + S7
`bin/mes-m2-64` via kaem.x86_64 (M2-Planet amd64); F1-64 sweep
(`--arch=x86_64 -m 64`), F2-64 via `M1 --architecture amd64` /
`blood-elf --64` / hex2 ELF64, F3-64 running the produced ELF64 mes
natively on the host kernel (FD §7.3). No asm.elf 64-bit backend required
(optional hardening, tracked separately, default: skip).
- Gate: `make fixpoint-64` clean.
- Risk: medium (mostly re-running proven machinery at a new width).
  Effort: 1–3 d + compute.

## Track D — zero Python (parallel/filler; only needs rsc + asm.elf)

### S9. Generator ports — [O], no hard deps (schedule after S6 for focus)
FD §8: five `tools/*.py` → dialect emitters, each gated by byte-identical
regeneration of its committed artifact; delete the .py files in the same
commits. Includes the frozen-qfasm.qf1 regenerator.
- Gate: `make regen && git diff --exit-code`; no *.py in tree.
- Risk: low. Effort: 1–2 d total, divisible into five independent chunks.

### S10. Docs + portability wrap — [O], needs S6 (S8 for the 64-bit claims)
ARCHITECTURE.md stage ladder update, Makefile entry points (`mesroot`,
`boot-gates`, `fixpoint`, `fixpoint-64`, `regen`), reference-hash workflow,
retire superseded plan sections.
- Effort: 0.5–1 d.

---

## Dependency graph and critical path

```
S0 → S1 → S2 → S3 → S4 → S5 → S6 ★ → S8 → done(64)
            └──────→ S7 ──────────────┘
S9, S10: off critical path (S9 anytime; S10 last)
```

Critical path to the i386 fixpoint: **7 stages (S0–S6)**, ~11–20 focused
days plus F1 compute. To the full two-arch, zero-Python endgame: **11
stages**, ~16–28 days. The single [F]-flavored items remaining are the S2
root-set review and any surprises S6 surfaces; everything else is
Opus-implementable from qmes-full-design.md as written.

## Standing rules (apply to every stage)

- Differential-first: every gate compares against `bin/mes-m2`(-64) on
  byte-exact outputs; never "looks right".
- third_party is read-only; all adaptation lives in the harness
  (build/mesroot, cut files, env).
- The three disciplines are review items on every VM-touching PR: tail-call
  rule (+ vm-run-nested exception), host-value-across-reset audit list,
  gc-only-at-gc-check.
- Determinism env-scrub table (mes-bootstrap-plan §5) on every MesCC
  invocation, both hosts.
