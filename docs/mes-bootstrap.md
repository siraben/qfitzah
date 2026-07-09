# The Mes campaign: from qmes to a self-hosting TinyCC

This is the narrative of the top of the ladder — how the qmes interpreter
(`docs/qmes.md`) is driven to the GNU Mes MesCC self-recompilation fixpoint on
i386 and x86_64, and then compiles a byte-identical, self-hosting TinyCC — with
no C and no Python in the build path.

The full invocation recipes live in the `tools/` scripts; this document keeps
the operational facts (what each gate proves, the determinism contract, the
reference/hash workflow, the results, and the honest limitation) and points at
the scripts rather than duplicating their prose.


## 1. Goal and strategy

qmes is a **transliteration** of GNU Mes 0.27.1's C core into the rsc dialect,
compiled through the qfitzah ladder into a native i386 ELF. It runs Mes's own
boot chain and MesCC unmodified. The endgame is Mes's own thesis, reached from
the qfitzah seed: MesCC (Mes's C compiler, interpreted Scheme) compiles Mes's
own `src/*.c` to a byte-identical self-recompilation fixpoint, and then
compiles TinyCC.

The strategy throughout is **differential-first**: every qmes behavior is
pinned against the M2-Planet reference Mes (`bin/mes-m2`, and `bin/mes-m2-64`
for amd64) by byte-exact comparison at the smallest possible granularity. A
transliteration bug surfaces as a byte diff on one boot cut, one scaffold file,
or one compiled `.s` unit — loud, bisectable, and localizable to a single
function. The reference is fast (Mes boots in well under a second); qmes is an
interpreted i386 process and runs 15–20× slower, but produces byte-identical
output. That ratio is a schedule cost, not a correctness risk.

Because MesCC, nyacc, and the whole boot-5 module chain are *interpreted* by
qmes, they add zero assembled instructions — the only thing qmes must assemble
is qmes itself. This is what makes the seed-arena escape (`asm.elf`, see
`ARCHITECTURE.md`) sufficient for the entire endgame.


## 2. The gates

### 2.1 The MesCC fixpoint: F1 / F2 / F3 (i386)

Over the 20 `mes_SOURCES` translation units of `src/*.c`:

- **F1** — path-independent MesCC *assembly*. `mescc -S -m 32 --arch=x86` over
  every unit under `qmes.elf` produces `.s` **byte-identical** to the same
  MesCC run under `bin/mes-m2`, compared per unit.
- **F2** — byte-identical *binary*. Linking each host's 20 `.s` (crt1 + units +
  libc, via mescc-tools' `M1`/`blood-elf`/`hex2`, identical invocation both
  sides) yields a byte-identical runnable `mes` binary from each path.
- **F3** — *self-recompilation*. Re-run the F1 sweep hosted on the F2 binary
  itself; all 20 units must match. This binary carries no M2-Planet ancestry —
  it is the qmes-lineage mes recompiling Mes.

### 2.2 The x86_64 variant: F1-64 / F2-64 / F3-64

The qmes-64 variant (`bootstrap/qmes.scm` + `bootstrap/qmes-w64.scm`; see
`docs/qmes.md` §8) runs MesCC targeting x86_64. F1-64 and F2-64 mirror F1/F2
with `-m 64 --arch=x86_64` against `bin/mes-m2-64`. F3-64 is not closed — see
§4.

### 2.3 The tcc rung: T0–T3

Against a reference TinyCC built under `bin/mes-m2`:

- **T0** — build the reference tcc under `bin/mes-m2` (10-unit sweep, link,
  stage libc, hello exit 42, self-host boot chain, `cmp boot5 boot6`) and
  commit the reference `.s` + binary hashes.
- **T1** — qmes compiles the same 10 units with bit-identical argv/env; `cmp`
  each `.s` against T0. Gate: 10/10 byte-identical.
- **T2** — link `tcc-mes.qmes` from the qmes `.s` set with the same
  mescc-tools; `cmp` the binary against the reference (path independence); then
  the hello gate using the qmes-built tcc.
- **T3** — the qmes-built tcc self-hosts: run the boot chain seeded by
  `tcc-mes.qmes`; gate `cmp tcc-boot5 tcc-boot6`.


## 3. The determinism contract

Byte-identity across two different host interpreters is only meaningful if
every other input is pinned. The harness (`tools/mescc-fixpoint.sh` and its tcc
sibling) enforces:

- **Scrubbed environment:** `env -i`, `LANG=`, `MES_DEBUG=0`, `%version=0.27.1`,
  fixed `MES_ARENA` / `MES_MAX_ARENA` / `MES_STACK`, run from the repo root.
- **Canonical `-o` paths.** MesCC embeds the `-o` path *and every `-D` string*
  verbatim in the emitted `.s` (measured: a 5-character-longer `-o` name grew
  the output by exactly 35 bytes). Both hosts get bit-identical argv, and `-o`
  is a repo-relative `canon/` path so the string is identical across hosts and
  machines. No absolute machine path appears in any `-D`.
- **The merged mesroot** (`tools/make-mesroot.sh`): both hosts run against the
  same synthesized `$MES_PREFIX` (see `docs/qmes.md` §6) and the same vendored
  nyacc, and the source files under `third_party/` are never patched.
- **A synthesized `config.h`.** Mes's build normally generates `mes/config.h`
  with `./configure`; the tree ships none. The harness writes the one line
  `#define MES_VERSION "0.27.1"` into `build/include/mes/config.h` and passes
  `-I build/include`. For tcc, the one synthesized file is likewise a one-line
  `config.h` (`#define TCC_VERSION "0.9.27"`), passed through `-I`; the tinycc
  submodule stays pristine.
- **Pinned link order** — the units are linked in the bootstrap.sh order, which
  affects the output bytes.


## 4. Results

- **sc1 and rsc self-host fixpoints** — the Stage 3/4 compilers recompile their
  own source to byte-identical fixpoints (run by `make check`).
- **asm.elf** — byte-identical to `[seed + qfasm.qf1]` on everything both can
  assemble, plus its own self-fixpoint.
- **qmes boot ladder** — qmes matches `bin/mes-m2`'s exit status across the
  scaffold/boot chain and the B0–B12 cut gates to `(top-main)`, and matches
  byte-exact stdout on the recorded boot gates.
- **i386 MesCC fixpoint — CLOSED.** F1 **20/20** byte-identical; F2
  byte-identical linked `mes` binary; F3 self-recompilation **20/20** on the
  qmes-lineage binary.
- **x86_64 MesCC — F1-64 20/20, F2-64 byte-identical, F3-64 not closed.**
- **tcc — T1 10/10, T2 byte-identical binary, T3 boot5 == boot6.** qmes
  compiles TinyCC to a binary byte-identical to the M2-Planet reference, and
  that tcc compiles and runs C and self-hosts to a byte-identical fixpoint. A
  genuine self-hosting TinyCC with no C compiler in its ancestry.

### 4.1 The F3-64 limitation (verbatim)

> Running the MesCC-linked amd64 `mes` binary to recompile `src/*.c` SIGSEGVs
> on the full mescc workload (even at MES_ARENA=300M) — but the
> **reference-path binary is byte-identical (`34c87cbc`) and crashes
> identically**, so this is a property of GNU Mes 0.27.1's amd64 MesCC-built
> binary under load, NOT of the qfitzah bootstrap or qmes64. The i386 fixpoint
> (`make fixpoint`) closes F1/F2/F3 fully; GNU Mes's amd64 MesCC self-hosting
> is less mature, and our bootstrap reproduces the reference's amd64 behavior
> exactly (identical binary).

So the x86_64 MesCC output of qmes-64 is path-independent and byte-identical to
the M2-Planet reference all the way to the linked binary — the substantive
x86_64 result — and F3-64 fails identically on both paths.


## 5. The reference and hash workflow

Two trust layers:

- **Reference (re)building** — Nix-gated, rarely run. `make mes-reference`
  builds `bin/mes-m2` the M2-Planet way (transcribing Mes's own `kaem.run` via
  nixpkgs m2-planet/mescc-tools); `ARCH=x86_64 make mes-reference` builds
  `bin/mes-m2-64`. `make tcc-reference` builds the reference tcc under
  `bin/mes-m2`. Each records a committed sha256 manifest under
  `tests/references/`.
- **Offline verification** — no toolchain beyond the committed seed and qmes.
  `make fixpoint-verify` runs only the qmes MesCC sweep and checks it against
  the committed hashes (`tests/references/mescc/fixpoint/`). `make tcc-verify`
  does the same for the qmes tcc `.s` sweep (`tests/references/mescc/tcc/`).
  These need no M2-Planet, no mes-m2, no mescc-tools.

The full `make fixpoint` / `make tcc` / `make fixpoint-64` targets run the
complete cross-host comparison (both hosts, link, self-host) and require the
reference binaries plus mescc-tools (self-entering a Nix shell). They are the
authority; the `-verify` targets are the fast offline gate that a fresh clone
can run.

Why the reference binaries `bin/mes-m2` / `bin/mes-m2-64` are tracked but not
trusted: they are the **comparison baseline**, never an input to any qfitzah
artifact. They are reproducible (`make mes-reference`) and hash-pinned
(`tests/references/mes-m2.sha256`), so tracking them lets a fresh clone verify
offline; trusting them is not required for the bootstrap claim.


## 6. The tcc rung in detail

**Pin: janneke/tinycc `mes-0.27` @ `0bbd2af3`** ("build: Remove -Dinline=
kludge."), vendored as the read-only submodule `third_party/tinycc`. The
rationale: Mes 0.27.1 pins no tcc commit; upstream's compatibility statement is
the *branch name* (`mes-0.27` is the branch for the 0.27.1 release, and the
pinned tip commit exists specifically because of 0.27.1). Its parent
(blynn's `ea3900f6`) has byte-identical C sources — `0bbd2af3` differs only in
build scripts — so this pin is the C tree a sibling project already validated,
with build scripts matched to our Mes version. The branch *is* the patch set
(a MesCC-compilable C89 subset with BOOTSTRAP guards and Mes-libc support); no
i386 patches are needed.

**Recipe: 10 translation units, single-step `-S`, at the pinned
`MES_ARENA=20000000`.** The maintained `bootstrap.sh` compiles ten separate
units (`tccpp tccgen tccelf tccrun i386-gen i386-link i386-asm tccasm libtcc
tcc`, in link order) rather than the ONE_SOURCE amalgamation. The
`MES_ARENA=200000000` figure in `third_party/mes/HACKING` is a stale 2017 note
(ONE_SOURCE, an older MesCC/nyacc, a 64-bit gcc-built mes); it is 5–10× larger
than anything the current recipe needs.

**Measured headroom** (under `bin/mes-m2`, the reference):

- All 10 units compile at `MES_ARENA=20000000`, peak RSS 233–245 MiB, 37–147 s
  each (~14.5 min sequential, ~2.5 min at 10-way parallel).
- The biggest unit (`tccgen.c`, 7,258 lines) compiles at MES_ARENA as low as
  2 M cells.
- qmes's fixed memory layout tops out near 60–65 M cells, so any single tcc
  unit (20 M pinned) has ~3× headroom; qmes compiled `i386-link.c`
  byte-identically to the reference at 643 MiB RSS.

Pin `MES_ARENA=20000000 MES_MAX_ARENA=20000000` everywhere and never shop for
cute arena values: mes-m2 has an arena-size-sensitive bug (a 5 M-cell run
segfaults where 2 M, 3 M, and 20 M all pass) that is *not* a memory requirement.

The one divergence found in the T1 sweep (initially 9/10) was a real qmes bug —
`b-ash` not masking the shift count mod 32 zeroed the high word of
`offsetof(TCCState, f)` static initializers in `libtcc.c` — now fixed and
documented as a C-quirk emulation (`docs/qmes.md` §9).

The full recipe (defines, libc `+tcc` flavor, staging, the self-host boot
chain) is `tools/build-tcc.sh`; see it for the exact invocations.

An x86_64 tcc is out of scope for this rung: it is blocked behind the same GNU
Mes 0.27.1 amd64 self-hosting limit as F3-64 (§4.1). The tcc rung stays on i386,
where the MesCC fixpoint fully closes.
