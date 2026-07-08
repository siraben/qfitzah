# qmes → MesCC → TinyCC: the next bootstrap rung (design + measured feasibility)

Status: DESIGN ONLY — no implementation in this commit. Everything below is
grounded in sources read this session and in **measurements actually run on
2026-07-08** with the committed `bin/mes-m2` and `./qmes.elf` on this machine
(32-core x86_64 host; all compilers are 32-bit i386 processes). The complete
prototype pipeline — MesCC compiles all of tcc, links it, the linked tcc
compiles a hello.c that runs, and tcc recompiles itself — was **executed
end-to-end in a scratchpad** before this document was written. Nothing here is
extrapolated from the 2017-era HACKING notes.

**One-line verdict: YES — qmes can compile the full TinyCC, with ~3× memory
headroom, using the modern 10-translation-unit recipe at the same
`MES_ARENA=20000000` the S6 fixpoint already uses.** The `MES_ARENA=200000000`
figure in `third_party/mes/HACKING:82` is obsolete (2017, ONE_SOURCE, an older
MesCC/nyacc, and a 64-bit gcc-built mes); it is 5–10× larger than anything the
current recipe needs, and the current recipe's needs were measured, not
guessed.

Headline measurements (details in §3, raw log in Appendix A):

- **All 10 tcc translation units compile under `bin/mes-m2` at
  MES_ARENA=20,000,000** (the `scripts/mescc.in` default and our fixpoint
  pin), peak RSS 233–245 MiB per unit, 37–147 s each.
- The biggest unit (`tccgen.c`, 7,258 lines) compiles at **MES_ARENA as low as
  2,000,000 cells** (35 MiB peak RSS).
- The ONE_SOURCE amalgamation (`-D ONE_SOURCE=1 tcc.c`) fails at 20 M cells and
  succeeds at **40,000,000 cells** (487 MiB RSS) — i.e. even the one-shot
  HACKING-style path needs 40 M, not 200 M, and *also* fits qmes.
- The MesCC-linked **`tcc-mes` (453,429 B i386 ELF) runs**, rebuilds the Mes C
  library with itself, and **compiles+links a hello.c that runs and returns
  exit 42**; `tcc-mes` then **recompiled all ten of its own sources and linked
  a working `tcc-boot0`** (253,932 B).
- **qmes compiled a tcc unit byte-identical to `bin/mes-m2`** (`i386-link.c`,
  identical `-o`, `cmp` clean), at 17.4× the mes-m2 wall time and 643 MiB RSS —
  comfortably inside qmes's fixed memory layout.

---

## 1. The tcc source to vendor

**Pin: `https://gitlab.com/janneke/tinycc.git`, branch `mes-0.27`, commit
`0bbd2af306a660fe19ad660034179ba973ca0449`** ("build: Remove -Dinline=
kludge.", 2025-07-22). Vendor as a read-only git submodule at
`third_party/tinycc`, exactly like `third_party/mes` / `third_party/nyacc`:

```
[submodule "third_party/tinycc"]
	path = third_party/tinycc
	url = https://gitlab.com/janneke/tinycc.git
```

(verified reachable: `git ls-remote` returns `0bbd2af3` as the
`refs/heads/mes-0.27` tip.)

Why this commit, against the three options in the brief:

- **(a) "the commit Mes 0.27.1 pins":** Mes 0.27.1 pins nothing. The release
  tree (`third_party/mes`) has no `.guix/`, no `guix.scm`, and its
  README/ANNOUNCE-0.27.1 only *link* to the janneke/tinycc repo. Upstream's
  compatibility statement is the **branch name**: janneke maintains one
  `mes-0.XX` branch per Mes release, and `mes-0.27` is the branch for our
  vendored 0.27.1. Its tip commit message says explicitly: *"Mes >= 0.27.1
  handles inline by removing it from the AST"* — the commit exists *because*
  of 0.27.1. This is as close to an upstream pin for 0.27.1 as exists.
- **(b) blynn's `ea3900f6`:** that is the **immediate parent** of `0bbd2af3`
  on the same branch. `git show --stat 0bbd2af3` touches only 4 shell scripts
  (`boot.sh bootstrap.sh build-32.sh cc.sh`, one deleted `-Dinline=` line
  each); **the C sources of the two commits are identical**. So pinning
  `0bbd2af3` gives us exactly the C tree a sibling project has already
  validated, plus build scripts matched to our Mes version. (Note blynn's
  *nix recipe* (`nix/tinycc-boot-hcc.nix`) actually builds mainline
  `repo.or.cz/tinycc` for HCC — its patches
  (`tinycc-mescc-source.patch`) are HCC/mainline-specific backports of things
  janneke's branch already contains, e.g. `s->static_link = 1` under
  `#if BOOTSTRAP` is at `libtcc.c:748` in our pin. Nothing from blynn's patch
  set is needed.)
- **(c) `master` (34b45a69, 2025-10-09 "Reverts & cleanups"):** newer than any
  Mes release, not named for 0.27, untested against it. Rejected.

**Patches needed for i386 + our libc: none.** The `mes-0.27` branch *is* the
patch set (MesCC-compilable C89 subset, BOOTSTRAP guards, Mes-libc
`TCC_MES_LIBC` support, `lib/libtcc1.c` counterpart in `mes/lib/libtcc1.c`).
The measured pipeline below ran the pinned tree unmodified. The only
synthesized file is **`config.h`** (upstream generates it with `./configure`,
which the bootstrap scripts never run): `tcc.h:25` does
`#include "config.h"`, and **MesCC resolves quoted includes through the `-I`
chain (verified)** — so the harness writes a one-off

```
#define TCC_VERSION "0.9.27"
```

into `build/tcc/include/config.h` and passes `-I build/tcc/include`; the
submodule stays pristine. (`0.9.27` is the tree's `VERSION`; `GCC_MAJOR` etc.
are only ever *written* by configure, nothing in the tree reads them.)

## 2. The exact MesCC invocation for our i386 setup

### 2.1 Which recipe: 10 units, not ONE_SOURCE, one-step `-S`

`HACKING:78-82` (the `-E` → `-c` two-step with 200 M arena) is a **stale 2017
bug note** ("compile tcc.E -> tcc.M1 segfaults"). The maintained recipe is the
`mes-0.27` branch's own **`bootstrap.sh`**, which:

- defaults `ONE_SOURCE=false` and compiles **10 separate translation units**
  (this is what makes the memory question easy):
  `tccpp.c tccgen.c tccelf.c tccrun.c i386-gen.c i386-link.c i386-asm.c
  tccasm.c libtcc.c tcc.c` — in that order, which is also the **link order**
  (pin it; link order affects bytes);
- uses single-step `mescc -S` per unit (no `-E`/`-c` split), then one
  `mescc -o tcc-mes … -l c+tcc` link;
- sets `MES_STACK=10000000` and inherits `scripts/mescc.in`'s
  `MES_ARENA=20000000` default.

With `-D ONE_SOURCE=1`, `tcc.c` `#include`s the other nine (confirmed: it
compiles standalone to a 2.98 MB `.s` at 40 M cells). Keep ONE_SOURCE as an
optional stunt (§5, T4); the 10-unit path is canonical and matches the F1
per-unit gating style we already have.

### 2.2 The compile invocation (measured, working)

Same env contract as `tools/mescc-fixpoint.sh:89-110` (env -i, `LANG=`,
`MES_DEBUG=0`, `%version=0.27.1`, `MES_PREFIX=build/mesroot`,
`srcdest=third_party/mes/`, `GUILE_LOAD_PATH=$root/mes/module`, run from repo
root), with `MES_ARENA=20000000 MES_MAX_ARENA=20000000` and
`MES_STACK=10000000` (bootstrap.sh's stack default; 5 M was not tested against
tcc — don't thin it without measuring). Per unit `u`:

```
$HOST --no-auto-compile -e main third_party/mes/module/mescc.scm -- \
  -S -m 32 --arch=x86 \
  -D BOOTSTRAP=1 \
  -D TCC_TARGET_I386=1 \
  -D 'CONFIG_TCCDIR="/usr/local/lib/tcc"' \
  -D 'CONFIG_TCC_CRTPREFIX="/usr/local/lib:{B}/lib:."' \
  -D 'CONFIG_TCC_ELFINTERP="/mes/loader"' \
  -D 'CONFIG_TCC_LIBPATHS="/usr/local/lib:{B}/lib:."' \
  -D 'CONFIG_TCC_SYSINCLUDEPATHS="/usr/local/include:{B}/include"' \
  -D 'TCC_LIBGCC="/usr/local/lib/libc.a"' \
  -D CONFIG_TCCBOOT=1 \
  -D CONFIG_TCC_STATIC=1 \
  -D CONFIG_USE_LIBGCC=1 \
  -D TCC_MES_LIBC=1 \
  -D 'TCC_LIBTCC1_MES="libtcc1-mes.a"' \
  -I build/tcc/include \
  -I third_party/tinycc \
  -I third_party/mes/lib \
  -I third_party/mes/include \
  -o build/tcc/canon/$u.s \
  third_party/tinycc/$u.c
```

Defines transcribed from `bootstrap.sh` (mes-0.27 tip, x86 arm of the case;
note `TCC_MES_LIBC=1` and `CONFIG_TCCBOOT=1` are *new* relative to
HACKING:81, and `-D inline=` is correctly absent for Mes ≥ 0.27.1). The
mescc-stage compile deliberately has **no** `HAVE_FLOAT`/`HAVE_LONG_LONG`/
`HAVE_SETJMP`/`HAVE_BITFIELD` — those are switched on stage-by-stage in the
native `boot.sh` chain (§2.5), never under MesCC.

Determinism rules (same class as F1):

- **MesCC embeds the `-o` path and every `-D` string verbatim** in the `.s`
  (measured: a 5-char-longer `-o` name grew the output by exactly 35 B). Both
  hosts must get bit-identical argv; `-o` must be the repo-relative
  `build/tcc/canon/<u>.s` path (mescc-fixpoint.sh's canon/ trick), and the
  `CONFIG_TCC_*` strings must be the fixed literals above — **no absolute
  machine paths in any -D** (the embedded search paths are only tcc's
  *runtime defaults*; our harness always passes `-B`/`-I`/`-L` explicitly, so
  the literals never need to resolve on the build host).
- config.h content is part of the recipe: exactly the one line in §1.

### 2.3 The libc: extend `tools/mescc-link.sh` with `libc+tcc`

tcc links against the **`libc+tcc`** flavor of the Mes libc
(`bootstrap.sh:148`: `mescc -o tcc-mes … -l c+tcc`). That is
`libc_tcc_SOURCES` from `third_party/mes/build-aux/configure-lib.sh:287` =
`libc_SOURCES` + ~50 stdio/stdlib/ctype/stub units — **159 units total** with
`mes_libc=mes mes_cpu=x86 compiler=mescc` (measured; all 159 compile clean
with the same `CPPFLAGS` mescc-link.sh already uses for libc). Add a
`libc+tcc` verb to `tools/mescc-link.sh` that:

1. compiles each unit with `mescc -c` into `build/mescc-lib/x86-mes/` (reusing
   `compile_c`, the SOURCES extraction via the config.sh stub, and the
   existing crt1.o);
2. mesar-archives **both** `libc+tcc.a` (cat of `.o`, 128,661 B measured) and
   **`libc+tcc.s`** (cat of the per-unit `.s`) — the `.s` archive is not
   optional: when mescc links from `.s` inputs (our case) it resolves `-l
   c+tcc` to `x86-mes/libc+tcc.s`, not the `.a` (hit and fixed during the
   prototype run).

### 2.4 The link (measured, working)

```
mescc -m 32 --arch=x86 -o build/tcc/tcc-mes \
  -L build/mescc-lib \
  build/tcc/canon/tccpp.s  build/tcc/canon/tccgen.s  build/tcc/canon/tccelf.s \
  build/tcc/canon/tccrun.s build/tcc/canon/i386-gen.s build/tcc/canon/i386-link.s \
  build/tcc/canon/i386-asm.s build/tcc/canon/tccasm.s build/tcc/canon/libtcc.s \
  build/tcc/canon/tcc.s \
  -l c+tcc
```

driven by the same `CC()` wrapper as `tools/mescc-link.sh:52-61` (needs
M1/hex2/blood-elf on PATH via `nix shell nixpkgs#mescc-tools`; `MES=` and
`M1=`/`HEX2=`/`BLOOD_ELF=` env). mescc auto-prepends `x86-mes/crt1.o` and
`-l mescc` from the `-L` path (it is not `-nostdlib`). Result: 453,429 B
static i386 ELF; `tcc-mes -vv` → `tcc version 0.9.27 (i386 Linux)`.

### 2.5 Runtime staging + self-host (what the built tcc needs to *work*)

Straight from `bootstrap.sh` (REBUILD_LIBC arm) and `boot.sh`, all executed
in the prototype:

1. **Amalgamated sources** per `build-aux/build-source-lib.sh` with
   **`compiler=gcc`** (this selects the `x86-mes-gcc` crt/setjmp variants
   whose gcc-style `asm(…)` tcc parses; the `compiler=mescc` variants are M1
   text and do *not* compile under tcc — hit and fixed in the prototype):
   `libc.c` = cat of `libc_gnu_SOURCES`, `libtcc1.c` = cat of
   `libtcc1_SOURCES` (= `mes/lib/libtcc1.c`).
2. `tcc-mes -c` each of `lib/linux/x86-mes-gcc/crt{1,i,n}.c`
   (`-static -nostdlib -nostdinc`), then `libc.c` → `tcc -ar cr libc.a`,
   `libtcc1.c` → `libtcc1.a`. CPPFLAGS for these:
   `-I build/include -I third_party/mes/include -I third_party/mes/lib
   -D BOOTSTRAP=1` (`build/include` supplies the `arch/*.h` symlinks that
   `ensure_env` in mescc-fixpoint.sh already creates — libc units include
   `<arch/syscall.h>`).
3. Stage layout `build/tcc/stage/`: `lib/{crt1.o,crti.o,crtn.o,libc.a}`,
   `libtcc1.a` **at the stage root** (with `-B <stage>`, tcc looks for
   `TCC_LIBTCC1_MES` under `{B}/` directly, not `{B}/lib/tcc/` — measured),
   plus `lib/tcc/libtcc1.a` for the installed-layout paths.
4. **hello gate**:
   `tcc-mes -B build/tcc/stage -I third_party/mes/include -L build/tcc/stage/lib -o hello hello.c`
   → ran, printed, **exit 42**. This is the "produces a working ELF" gate.
5. **Self-host chain** (`boot.sh` semantics, all native-tcc, fast):
   - boot0 flags: `-D BOOTSTRAP=1 -D HAVE_LONG_LONG_STUB=1 -D HAVE_SETJMP=1`
     (+ §2.2's CONFIG block, minus nothing) — tcc-mes recompiles all 10 units
     and links `tcc-boot0` (**built and runs**, 253,932 B — smaller than
     tcc-mes because tcc's codegen beats MesCC's);
   - boot1: `+ HAVE_BITFIELD=1, HAVE_LONG_LONG_STUB→HAVE_LONG_LONG=1`;
   - boot2: `+ HAVE_FLOAT_STUB=1`; boot3..: `HAVE_FLOAT=1`;
   - iterate to boot5/boot6 and **`cmp tcc-boot5 tcc-boot6`** — upstream's own
     built-in self-host fixpoint check (`bootstrap.sh:224-231`). Also rebuild
     crt/libc/libtcc1 with the final tcc (bootstrap.sh does; keeps the chain
     honest).

## 3. Feasibility — measured, quantitative

### 3.1 What the tcc compile actually needs (measured under `bin/mes-m2`)

All 10 units at the pinned `MES_ARENA=20000000 / MES_STACK=10000000`
(parallel-10 run, so walls are contention-inflated; standalone `i386-link.c`
is 37 s):

| unit | lines | wall | peak RSS | .s bytes |
|---|---|---|---|---|
| tccpp.c | 3,896 | 128 s | 245 MiB | 869,286 |
| tccgen.c | 7,258 | 147 s | 239 MiB | 852,570 |
| tccelf.c | 3,082 | 97 s | 235 MiB | 388,195 |
| tccrun.c | 842 | 53 s | 233 MiB | 24,364 |
| i386-gen.c | 1,168 | 66 s | 234 MiB | 101,837 |
| i386-link.c | 246 | 52 s | 234 MiB | 29,615 |
| i386-asm.c | 1,720 | 124 s | 237 MiB | 235,697 |
| tccasm.c | 1,379 | 66 s | 234 MiB | 163,591 |
| libtcc.c | 2,030 | 74 s | 234 MiB | 198,867 |
| tcc.c | 362 | 61 s | 234 MiB | 127,143 |

(Σ wall ≈ 14.5 min sequential-equivalent; ~2.5 min at 10-way parallel.
Peak RSS ≈ the 22 M-cell (arena+jam) × 12 B allocation — the arena dominates
and the *default is already generous*.)

Arena bisection on the biggest unit, `tccgen.c`: **2 M cells suffices**
(35 MiB RSS, 275 s — slower from GC churn); 3 M ✓, 10 M ✓, 20 M ✓. (5 M
segfaulted in 5 s — that is mes-m2's known arena-size-sensitive bug
(HACKING "segfaults with small arena"), *not* a memory requirement: smaller
2 M/3 M and larger arenas all pass. Consequence: **pin MES_ARENA=20000000 and
never shop for cute arena values in CI**.)

ONE_SOURCE `tcc.c`: 20 M ✗ (segv after 272 s ≈ arena exhaustion), **40 M ✓**
(487 MiB RSS, 448 s, 2,976,766 B `.s`). So even the amalgamated path needs
1/5th of HACKING's 200 M. The 200 M figure dates from v0.15-era MesCC/nyacc
(quadratic-ish behavior since fixed) on a 64-bit gcc-built mes; treat it as
historical.

### 3.2 Can qmes hold this? (the 32-bit ceiling, computed from the layout)

qmes's memory model (all fixed at build time; `bootstrap/gen-rsc-runtime.scm`
HeapInit + `bootstrap/qmes.scm` qmain):

- rsc **host pair heap**: 512 MiB span `[CodeEnd, +0x20000000)`, reclaimed at
  the VM trampoline (`host-heap-reset!`), tripwired at 496 MiB.
- rsc **byte heap**: 1 GiB `[+0x20000000, +0x60000000)` — bump-only. This is
  where every rsc vector/string lives, i.e. where the Mes arena goes:
  - `g-cells` = 3 raw w32 words/cell × (ARENA + JAM=ARENA/10) → **13.2 B per
    MES_ARENA cell**;
  - `g-stack` = 4 B × MES_STACK (40 MB at the 10 M stack);
  - the two-space Mes byte pool = 2 × 16 MiB (fixed `BYTE-POOL`,
    `qmes.scm:169`);
  - misc long-lived rsc allocations (small).
- read/token buffers 32 MiB; total brk span `0x62000000` (`rsc.scm` bss
  constant, the S5 GC-fix layout).

Ceiling: `13.2·A + 40 MB + 32 MiB + slack ≤ 1 GiB` → **A_max ≈ 60–65 M
cells** with ~100 MB slack reserved. Against the measured needs:

| workload | cells needed | qmes headroom |
|---|---|---|
| any single tcc unit (10-unit recipe) | 20 M (pinned; 2–3 M true min for tccgen) | **~3×** |
| ONE_SOURCE tcc.c | 40 M | ~1.6× |

**The premise of the "crux" question dissolves on measurement: 200 M cells is
not needed, and what is needed (20 M) is what qmes already runs the S6
fixpoint at.** No qmes memory-model change is required. (If more were ever
needed: the process tops out at ~1.7 GiB of a 3 GiB space, so the byte-heap
constant (`gen-rsc-runtime.scm` HeapInit `0x40000000` + `rsc.scm` bss
`0x62000000`) could grow another ~1.2 GiB → A_max ≈ 150 M cells; a
deterministic two-constant change of the same class as the S5 bss bump.
Recorded for completeness; **not proposed**.)

Empirical confirmation (the number that matters): **qmes compiled
`i386-link.c` at ARENA=20 M in 643 MiB RSS, exit 0, output `cmp`-identical to
`bin/mes-m2`'s with the same `-o`**, at 643 s vs 37 s (17.4× — same
interpreted-MesCC ratio as the S6 sweep). Projected full-sweep cost under
qmes: ≈ 17× × 14.5 min ≈ **4.1 CPU-hours, ~30–60 min wall at 10-way
parallel** (10 × ≤0.7 GiB = 7 GiB host RAM — fine). Slower than the 16-min F1
gate but the same order of ceremony; the reference sweep stays minutes.

### 3.3 Feasibility verdict

- **Full tcc under qmes: YES**, via the canonical 10-unit recipe, at the
  already-pinned arena. Nothing to shrink, split, or stage.
- ONE_SOURCE also fits (40 M < 65 M) — optional demonstration, not the path.
- Practical qmes ceiling for *any* future MesCC workload: ~60–65 M cells ≈
  3× the largest thing tcc requires; mes.c-scale is nowhere near the limit.

## 4. Verification gates & the reference

Mirror F1/F2/F3 exactly; the reference is the same tcc built under
`bin/mes-m2` (fast), byte-compared against the qmes build.

- **T0 (reference build + upstream fixpoint):** under `bin/mes-m2`: 10 units →
  `tcc-mes.ref` → stage libc → hello (exit 42) → boot chain →
  `cmp tcc-boot5 tcc-boot6`. Commit
  `tests/tcc-references/t0.sha256` (10 `.s` + `tcc-mes.ref` + `tcc-boot5`
  hashes). *Everything in T0 already ran in the prototype except the
  boot1–boot6 tail (boot0 built & runs).*
- **T1 (qmes F1-analog — the thesis gate):** qmes compiles the same 10 units
  with bit-identical argv/env and canonical `-o`; `cmp` each against T0.
  Gate: **10/10 byte-identical**. (1/10 already proven.)
- **T2 (link + run):** link `tcc-mes.qmes` from the qmes `.s` set with the
  same mescc-tools; `cmp tcc-mes.qmes tcc-mes.ref` (byte-equal binaries —
  F2-analog, path independence); then the hello gate *using the qmes-built
  tcc*.
- **T3 (tcc self-host fixpoint):** run the boot chain seeded by
  `tcc-mes.qmes`; gates: `cmp tcc-boot5 tcc-boot6` (self-host fixpoint) and
  `cmp` of the whole boot artifact set against T0's (given T2's byte-equal
  seed and a deterministic chain, divergence = harness bug).

Achievability given §3: **all four gates are achievable**; none is
memory-gated. T1 is the only expensive one (~4 CPU-hours) and the only one
with real technical risk (§5).

## 5. Staging, tooling shape, effort, risk

Vendoring + build shape (portability contract unchanged: qmes path needs no
C and no Python; mescc-tools + the mes-m2 reference stay nix-gated):

- `third_party/tinycc` submodule @ `0bbd2af3` (read-only, like mes/nyacc).
- `tools/build-tcc.sh` with verbs mirroring the existing harnesses:
  - `libc` — delegate to `tools/mescc-link.sh libc+tcc` (§2.3);
  - `compile HOST OUTDIR [JOBS]` — the 10-unit sweep of §2.2 (canon `-o`,
    parallel, per-unit logs), plus synthesis of `build/tcc/include/config.h`;
  - `link SDIR OUT` — §2.4;
  - `stage TCC` — §2.5 steps 1–3;
  - `hello TCC` / `boot TCC` — §2.5 steps 4–5;
  - `t0` / `verify [JOBS]` / `fixpoint` — the T0 / T1 / T2+T3 drivers with
    committed-hash checking, patterned on `mescc-fixpoint.sh verify`.
- `Makefile`: `tcc-reference` (T0, nix-gated like `mes-reference`), `tcc`
  (T1+T2 via qmes), `tcc-fixpoint` (T3), `tcc-verify` (offline qmes-only
  sweep against committed hashes, like `fixpoint-verify`).
- All intermediates under `build/tcc/`; no writes to `third_party/`.

Stages, effort, gates:

| stage | work | effort | gate |
|---|---|---|---|
| T0 | port prototype scripts into `tools/build-tcc.sh` + submodule + hash manifests + boot1–6 tail | 1–1.5 d | ref tcc self-host fixpoint + hello; hashes committed |
| T1 | qmes sweep wiring (`tcc-verify`), run, chase any divergence | 0.5 d + ~1 h wall compute (+ unknown if divergence) | 10/10 `.s` byte-identical |
| T2 | link from qmes `.s`, cmp binary, hello via qmes-built tcc | 0.5 d | binary byte-equal + hello exit 42 |
| T3 | boot chain driver seeded from qmes tcc | 0.5–1 d | boot5 == boot6 == T0 boot5 |
| T4 (optional) | ONE_SOURCE under qmes @ ARENA=40 M (~2 h single compile) | 0.5 d | amalgam `.s` byte-identical to mes-m2's |

**Biggest risk — a qmes↔mes-m2 divergence in one of the 9 not-yet-swept
units.** Each new unit exercises MesCC/nyacc/libc-header paths the 20
`src/*.c` units didn't (token pasting in tccpp, the giant switch/string
tables in i386-asm, `long long` constant folding paths, `setjmp.h` use).
History says every such divergence so far (S5's assq/value-equality, reader
radix, escape set…) was a *fixable qmes gap with a loud, bisectable
signature* — the gate design (per-unit cmp against a fast reference) is
precisely the divergence-hunting machinery that fixed them. This is a
schedule risk, not a feasibility risk; the one unit already swept came out
byte-identical on the first try.

Secondary risks, with mitigations already baked in:

- *mes-m2 arena-size sensitivity* (the 5 M-cell segfault): pin
  `MES_ARENA=20000000 MES_MAX_ARENA=20000000 MES_STACK=10000000` everywhere,
  both hosts, forever; never tune per-unit.
- *Determinism leaks via embedded strings*: `-o` canon paths and fixed `-D`
  literals only (§2.2); config.h content pinned; link input order pinned to
  the bootstrap.sh list.
- *qmes host-heap pressure at tcc scale*: the S5 tripwires (`exit 3`/`exit 4`)
  turn any overflow into a loud failure, and the measured 643 MiB run shows
  ~35% headroom on the observed peak; tccgen under qmes is the case to watch
  (if it trips, the existing chunked-reset discipline is the fix, same as
  S5's `read-forms-loop`).
- *boot-chain environment drift*: boot.sh is upstream's; we drive the same
  compiler invocations from our own script with explicit `-B`/`-L`/`-I`
  (no `/usr/local` reliance), as the prototype did.

Out of scope for this rung, recorded: an x86_64 tcc (`TCC_TARGET_X86_64` is
supported by the branch's scripts) is blocked behind the known GNU Mes
0.27.1 amd64 self-hosting limit (F3-64, `docs/qmes-x86_64-status.md`); the
tcc rung stays on i386 where the MesCC fixpoint fully closes. And the ladder
*above* tcc (tcc → old gcc → …) is live-bootstrap's territory — once T2/T3
land, qfitzah's artifact plugs into that chain as a drop-in `tcc-mes`.

---

## Appendix A: raw measurement log (2026-07-08)

Setup: pinned tinycc `0bbd2af3` cloned to a scratchpad; `config.h` = one
line (§1); env/argv per §2.2 with absolute scratchpad `-I`/`-o` (fine for
measurement; canon paths required for committed hashes). Host compiler
`bin/mes-m2` (M2-Planet reference, i386); qmes = committed `./qmes.elf`.

```
# 10-unit sweep, bin/mes-m2, ARENA=20e6 STACK=10e6, 10-way parallel
exit=0 wall=128.0s maxrss=245MiB out=869286B src=tccpp.c
exit=0 wall=146.5s maxrss=239MiB out=852570B src=tccgen.c
exit=0 wall= 96.5s maxrss=235MiB out=388195B src=tccelf.c
exit=0 wall= 53.3s maxrss=233MiB out= 24364B src=tccrun.c
exit=0 wall= 65.5s maxrss=234MiB out=101837B src=i386-gen.c
exit=0 wall= 52.2s maxrss=234MiB out= 29615B src=i386-link.c   (37s standalone)
exit=0 wall=123.5s maxrss=237MiB out=235697B src=i386-asm.c
exit=0 wall= 66.1s maxrss=234MiB out=163591B src=tccasm.c
exit=0 wall= 74.2s maxrss=234MiB out=198867B src=libtcc.c
exit=0 wall= 61.3s maxrss=234MiB out=127143B src=tcc.c

# tccgen.c arena bisection (mes-m2)
ARENA= 2e6  exit=0   wall=275.3s maxrss= 35MiB
ARENA= 3e6  exit=0   wall=223.3s maxrss= 46MiB
ARENA= 5e6  exit=-11 wall=  4.9s            <- mes-m2 small-arena bug, not a requirement
ARENA=10e6  exit=0   wall=176.0s maxrss=125MiB
ARENA=20e6  exit=0   (sweep above)

# ONE_SOURCE tcc.c (mes-m2)
ARENA=20e6  exit=-11 wall=272.4s maxrss=254MiB
ARENA=40e6  exit=0   wall=448.4s maxrss=487MiB out=2976766B

# libc+tcc (mes-m2 mescc -c, 159/159 units OK) -> libc+tcc.a 128661B (+ .s archive)
# link: mescc -m 32 --arch=x86 -o tcc-mes -L <libdirs> <10 .s> -l c+tcc
#   -> tcc-mes 453429B static i386 ELF; `tcc-mes -vv` = "tcc version 0.9.27 (i386 Linux)"
# stage: tcc-mes -c crt{1,i,n}.c(x86-mes-gcc), libc.c(libc+gnu amalgam), libtcc1.c; tcc -ar
# hello: tcc-mes -B stage -L stage/lib -o hello hello.c -> "Hello, tcc-mes!", exit 42
# boot0: tcc-mes recompiles all 10 units + links -> tcc-boot0 253932B, runs (-vv OK)

# qmes.elf, i386-link.c, ARENA=20e6 STACK=10e6
exit=0 wall=643.3s maxrss=643MiB out=29650B
cmp vs bin/mes-m2 same -o: BYTE-IDENTICAL

# quoted-include check: config.h moved out of the tcc tree, supplied via -I dir
exit=0 (mescc resolves #include "config.h" through -I; submodule can stay pristine)
```

Notes for the implementer, learned the hard way:

- `-l c+tcc` from `.s` inputs needs `x86-mes/libc+tcc.s` (mesar cat of unit
  `.s`), not just the `.a`.
- `mescc` link (non-`-nostdlib`) auto-resolves `crt1.o` *and* `libmescc.a`
  via `-L`; keep `build/mescc-lib` on the `-L` path.
- The tcc-built libc must be generated from the **`compiler=gcc`** source
  variants (`x86-mes-gcc` crt*/setjmp, gcc-style asm). The `mescc` variants
  are M1-macro asm and fail under tcc with `bad expression syntax`.
- libc units need `<arch/*.h>` → `-I build/include` (the `ensure_env`
  symlinks).
- With `-B <dir>`, tcc resolves `TCC_LIBTCC1_MES` ("libtcc1-mes.a") and
  `libtcc1.a` at `{B}/` root — stage a copy there, not only in `lib/tcc/`.
- tcc option parsing: it's `-v`/`-vv`, `--version` is not a thing; and
  `error:`-path exits can segfault (no HAVE_SETJMP at the mescc stage) —
  don't read crashes-after-error as compile failures.
```
