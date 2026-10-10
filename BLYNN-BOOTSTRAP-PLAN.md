# qfitzah → Blynn/HCC → TCC

## Completed objective

Fresh acceptance passed on 2026-10-10 in **24m11.371s**. The completion audit
is recorded in `bootstrap/blynn/ACCEPTANCE.md`.

User-directed retarget on 2026-10-10: stop pursuing the MesCC route and use
https://github.com/siraben/blynn-bootstrap to bootstrap TCC. The source-only
seed boundary and fresh complete-build target of less than four hours remain.

Pinned target revision: `db5fe7b533f67da246164d0e9017346fea821631`.
Inspection checkout: `/tmp/qfitzah-blynn-upstream`. The existing checkout at
`/home/siraben/blynn-bootstrap` is older and has untracked `ccc/`; leave it alone.

## Requirements

- Only the explicitly trusted qfitzah seed supplies a compiler binary root.
  No host C/Haskell/Scheme compiler, assembler, linker, or prebuilt stage0 tool.
- Host fetching, unpacking, shell orchestration and monitoring remain separate.
- Pin and verify sources; audit handwritten source versus generated artifacts,
  especially stage0 annotated assembly and Blynn's initial combinator programs.
- Regenerate VM/compiler images, HCC C output and object IR along the chain.
- Validate TCC execution, usable runtime, self-rebuild and reproducibility.
- Time an entirely fresh chain including the new entry bridge and all compiler
  stages, not a cached Nix derivation or a checkpoint recovery.
- Preserve checkpoints and use immutable recipes and 15-minute monitoring.

## Verified route

The target's amd64 portable compiler path is:

    stage0 → M2-Planet/M2-Mesoplanet → Blynn → HCC → TinyCC

Do NOT invoke its default launcher unchanged: `bootstrap-tools.sh` executes
imported hex0/kaem seed binaries. Its external-tool mode also does not verify
provenance. Neither alone establishes a qfitzah-rooted build.

Verified entry bridge: compile a small hex0-compatible tool through qfitzah's
Scheme stages, assemble handwritten stage0 hex0 source, prove its self-copy,
and assemble kaem from source. Source-built kaem then drives the unchanged
mini/full stages through phase 15. All six tool hashes match upstream's
post-build answer file. No imported hex0 or kaem binary enters this build.

## Work ledger

- [x] Stopped task 155 and its watcher 156 immediately on user direction.
  No processes referencing `/tmp/qfitzah-native-e2e` remained in the subsequent
  process check. Preserved the output tree and immutable recipe.
- [x] Recorded `cancelled_user_retarget`, approximately 208m17s, in
  `/tmp/qfitzah-native-e2e.timing`. This is neither a fresh success nor a
  compiler failure; no four-hour acceptance claim.
- [x] Inspected target README, shared source pins, portable orchestration,
  stage0 bootstrap script, root Blynn ladder and performance documentation.
- [x] Task 157 (`bg_8g9v_mv2j05p0_157`) fetched pinned source trees in 17s
  without executing seeds, into `/tmp/qfitzah-blynn-sources`. Git commit/tree
  identities are recorded in `source-commits.tsv` and pinned in
  `bootstrap/blynn/sources.tsv`.
- [x] Implemented `bootstrap/blynn/hex0.scm` and `build-hex0.sh`: a strict
  annotated-hex source assembler compiled through rsc. It validates before
  opening output. Tests cover all 256 byte values, comments, malformed input,
  and preservation of an existing output on invalid source. It reproduced the
  AMD64 hex0 byte-for-byte (upstream binary used only as a post-build oracle),
  SHA256 `66c95985e668f20f2465c2b876f83fef066fd7c8c2dd3adb51a969f2d7120c8b`.
- [x] Task 158 (`bg_8g9v_mv2j8a7m_158`) passed in **53.497s**, testing the complete qfitzah-rooted M2
  handoff in `/tmp/qfitzah-blynn-tools-first`, rebuilding its own Scheme stages.
  `export-stage0.sh` exports pinned Git objects, not mutable worktrees, and
  excludes bootstrap-seeds. `build-blynn-tools.sh` assembles hex0, proves its
  self-reproduction, builds kaem from source and runs the unchanged upstream
  mini/full stages through phase 15. All six tool hashes matched. Watcher
  159 was stopped.
- [x] Added a small source compiler for Blynn's untyped `singularity` language:
  named lexer/parser helpers and direct SKI bracket abstraction, compiled through
  rsc. It compiled the actual 66-line source into 4,573 bytes of ION text in
  0.049s. Task 160 (`bg_8g9v_mv2jjzw7_160`) then used a qfitzah/M2-built VM to
  self-compile that source: byte-identical output, SHA256
  `e604c21140ebf8a92634d261d6304b34d3c8eccec6575d63a807be8e48ed4672`, in ~2s.
  Independent tests cover parsing errors/no partial output, bracket-abstraction
  goldens, lexical shadowing, identity I/O and character-prefix execution.
- [x] Task 161 (`bg_8g9v_mv2jw767_161`) passed compiler byte equality through
  both rsc lineages and the native root Blynn ladder (**7m41.490s**), output
  `/tmp/qfitzah-blynn-root-first`. Prepared sources have their `blob/` directory
  removed: all starting code comes from `singularity` source. `root.sha256`
  records the completed artifacts. Watcher 162 was stopped.
  A documented local VM safety patch initializes `buf_end` after allocation,
  bounds raw-input loading and terminates its buffer. Upstream sources remain
  unchanged; target patches and this repair apply to a fresh export.
- [x] Task 163 (`bg_8g9v_mv2jwznd_163`) fetched the pinned Mes *libc source*
  for HCC: commit `c331d801da386ba752f3fe92d0538102a90e988d`, tree
  `656fe9c4b829a177e9a84f6deaab7673e563d7ad`. This route runs neither Mes
  nor MesCC. `prepare-blynn-tcc.sh` passed source export, exact patching and
  libc aggregation in `/tmp/qfitzah-blynn-tcc-prepared`. `compiler=gcc` in
  its configuration selects assembly-source syntax only; no GCC is invoked.
- [x] Task 166 (`bg_8g9v_mv2kjii1_166`) passed current Blynn/precisely and
  HCC in `/tmp/qfitzah-blynn-hcc-corrected` in **10m02.872s**. HCC's preprocessor,
  C compiler and M1 emitter were all compiled through M2. Watcher 167 stopped.
  Task 164 stopped during patch preparation, before compilation: stale or
  asymmetric upstream patch context failed exact application. Local context
  repairs now permit the entire series with `--fuzz=0`, preserving intended
  code changes. Prepared source trees matched a separately applied reference
  series (excluding patch backup files). Task 165 observed that initial failure.
- [x] Task 169 (`bg_8g9v_mv2lar2h_169`) built HCC-seeded TinyCC, verified its
  native stage-2/stage-3 byte equality, and ran the upstream executable smoke
  test, in **2m37.308s**. Output: `/tmp/qfitzah-blynn-tcc-first`. Execution trace:
  `/tmp/qfitzah-blynn-tcc-first.execve`. The independent suite then failed because
  its historical ABI assertion required four-byte pointers. Parameterizing that
  assertion for amd64 made both C/ABI/repeated-output tests pass. The numeric
  test then failed with code 3, exposing the target libc's limited decimal
  converter. Watcher 170 stopped. This is not runtime acceptance yet.
- [x] Task 171 (`bg_8g9v_mv2llsuq_171`) completed native runtime rebuilding and
  C/numeric tests, but log audit caught duplicate `alloca` diagnostics despite
  exit zero. That preliminary output is not acceptance evidence. The corrected
  finalizer excludes Mes's heap allocator and links TinyCC's native assembly
  allocator. A minimal TinyCC driver patch preserves object-loading error
  counts before output; a new duplicate-symbol/no-output regression passes.
  `/tmp/qfitzah-blynn-tcc-final-checked` passed three native rebuild rounds,
  final compiler/library byte fixpoints, C/numeric tests and strict diagnostics
  in **5.814s**, with no `error:` diagnostics. Final TCC SHA256:
  `a0f2cf6210f0092c17a5b7bbc831e91705300cee3ddb407aafd2b38c3bd83cf5`.
  Its decimal repair is GNU-Mes-derived source, not a historical compiler.
  Recipe: `/tmp/qfitzah-blynn-runtime-checked-source.qpM28y`.
- [x] Source-entry audit added rejection of forward/self global references:
  the VM initializes its table sequentially; recursion uses explicit `@Y`.
  Both rsc lineages passed the new guards, 224-definition boundary and VM tests;
  the actual starting compiler image is unchanged. Artifacts:
  `/tmp/qfitzah-singularity-guards.Tu3kkR`. Fast bridge tests are now in `tests/run.sh`.
- [x] Task 168 (`bg_8g9v_mv2l9p3e_168`) passed immutable complete qfitzah checks
  in **7m57.434s**, including the new bridge tests through both compiler lineages.
  This is regression evidence, not fresh TCC timing.
- [x] `build-blynn.sh` assembles the complete fresh recipe: verified seed,
  clean environment, forbidden host-compiler fallbacks, immutable source copies,
  both bridge lineages, every compiler stage, native runtime fixpoints and tests.
  `/proc/uptime` measures total/phase timing; existing outputs and wrong seeds
  are rejected. Failure-metadata/guard tests and the full chain passed.
  `fetch.sh` verifies all required source pins without executing
  or even requiring the separate upstream seed binaries.
- [x] Task 172 (`bg_8g9v_mv2lwv70_172`) passed the complete fresh recipe,
  16:26–16:50 UTC, output `/tmp/qfitzah-blynn-e2e`, in **24m11.371s wall**.
  Recipe monotonic time: **1451.26s**. No generated compiler artifacts were
  reused. Execution trace: `/tmp/qfitzah-blynn-e2e.execve`. Final compiler and
  all six runtime files also matched independently built component outputs
  (post-generation oracles only). Watcher 173 was stopped after completion.
- [x] Component relocation audit passed the full C/numeric/diagnostic suite from
  a new prefix (`/tmp/qfitzah-blynn-relocation.path` records its location). ELF64
  inspection found no interpreter segment; archive timestamps are all zero;
  the compiler contains no build/home/Nix-store prefix. Dependency and license
  roles are recorded in `bootstrap/blynn/DEPENDENCIES.md`.
- [x] Added `tests/blynn-sources.sh` and a separate Nix source-boundary check.
  It verifies dirty/untracked worktree isolation, ignoring Git replacement
  objects, rejection of wrong trees and existing outputs, object-only fetching,
  and omission of the unused seed oracle. Foreground tests and immutable task
  174 (`bg_8g9v_mv2mc3hp_174`, 2m13.729s) passed. No compiler-source changes
  were needed; the running fresh recipe remains unchanged.
- [x] The fresh root stage finished; its VM and all four native compiler
  binaries match the independent component build byte-for-byte. Checksums
  verified; evidence is `root-cross-build-reproducibility.txt` in the fresh tree.
- [x] Final audit passed: `audit.json` verifies the seed, 309 recipe files, all
  compiler/runtime manifests, fixpoints, phases, static ELF/archive properties,
  external executable categories and independent final outputs. Relative exec
  paths were manually matched to the scripts' working directories. No host
  compiler/assembler/linker/archiver or extra executable seed was used; the
  complete log contains no error/fatal/FAIL diagnostics. All ten current Blynn/
  HCC binaries also match the independent build. Source notices and license
  copies remain intact; bootstrap libc limitations are explicit. Historical
  Mes artifacts still exist, and the original Blynn checkout has no tracked
  changes. Final evidence and commands: `bootstrap/blynn/ACCEPTANCE.md`.

Historical Mes work and its evidence remain in `BOOTSTRAP-PLAN.md`; they are
not the active implementation plan. Existing recovered TCC binaries must not
become compiler inputs to this new route.
