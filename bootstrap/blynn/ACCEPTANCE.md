# Fresh Blynn/TCC bootstrap acceptance

Verified on 2026-10-10, amd64 Linux with i386 execution support.
Target: `siraben/blynn-bootstrap` at
`db5fe7b533f67da246164d0e9017346fea821631`.

## Result

**Fresh complete build: 24m11.371s wall**, including execution tracing, recipe
snapshotting and post-generation comparison against an independent component
build. The recipe's Linux `/proc/uptime` measurement was **1451.26 seconds**.
This is below the 14,400-second acceptance limit. It was not a checkpoint
recovery or cached Nix build. Pinned source Git objects were already available;
no generated compiler artifact was reused.

| Measured recipe phase | Seconds |
|---|---:|
| Verify pinned source objects | 0.12 |
| qfitzah/Scheme → hex0 → stage0/M2, including bridge tests | 67.79 |
| Both singularity compiler lineages and unit tests | 14.19 |
| Source-entry root Blynn ladder and VM tests | 441.97 |
| Current Blynn and HCC | 758.12 |
| HCC → TCC, native runtime/compiler rebuilds and tests | 168.43 |

Small orchestration/hash overhead accounts for the remainder.

Final compiler: **TinyCC 0.9.28-unstable-2025-12-03**, static ELF64 amd64.
SHA256: `a0f2cf6210f0092c17a5b7bbc831e91705300cee3ddb407aafd2b38c3bd83cf5`.

## Requirement audit

- **Requested route:** the complete recipe follows qfitzah → Scheme → stage0/M2
  → source-entry Blynn → current Blynn/HCC → TinyCC. Every phase passed.
- **Trusted seed boundary:** the 2,544-byte seed matched
  `abd1975d1145c4ed808b2cac6e2265df958f1052a6b459b28664bcbcde8906aa`.
  The execution trace contained only descendants built in the fresh tree and
  allowed host orchestration/file utilities. No host C/Haskell/Scheme compiler,
  assembler, linker, archiver or extra executable seed was used downstream.
  Relative execution paths were reviewed against the stage0 mini/full scripts,
  the TinyCC script's artifact-directory scope, and the native finalizer's
  source-directory scope. Failed PATH-search attempts are included in the audit.
- **Libc boundary:** a subsequent strengthened audit checked every retained ELF
  executable (9 i386 and 55 amd64): none has `PT_INTERP` or `PT_DYNAMIC`.
  M2libc, bootstrap libc, startup code and TinyCC runtime helpers are built from pinned
  source inside the chain, not imported from a higher libc. Host utilities may
  use the host libc; this is a declared orchestration boundary, not a bootstrap
  of the entire host OS. Header/library search provenance is documented in
  `DEPENDENCIES.md`.
- **Generated artifacts:** the root `blob/` directory and exported upstream
  `bootstrap-seeds` directory were absent. The starting combinator program came
  from `singularity` source and reproduced itself. Later compiler images, HCC
  object IR/C, M1, native binaries, runtime objects and archives were regenerated.
- **Working compiler/runtime:** C/ABI, signed/unsigned wide arithmetic, floating
  arithmetic/conversion, VLAs, allocation, file I/O and repeated-output tests
  passed. Invalid syntax and duplicate strong symbols failed without an output.
  The complete build log contained no error/fatal/FAIL diagnostics; remaining
  upstream warnings are not presented as standards-conformance evidence.
- **Self-rebuild:** bootstrap TCC stage 2 equaled stage 3. Three native runtime/
  compiler rounds then produced matching final compiler and library artifacts.
- **Independent reproducibility:** all root/current Blynn and HCC binaries
  matched the earlier independent component build. The final TCC and all six
  shipped runtime files also matched across build directories. Archive dates
  are zero; the final compiler has no host/build prefix or ELF interpreter.
  A relocated component copy passed the same runtime/diagnostic tests.
- **Regressions and source provenance:** immutable full qfitzah checks passed
  in 7m57.434s, including both bridge lineages. Separate source-boundary tests
  passed directly and under Nix, checking dirty worktrees, replacement objects,
  incorrect pins, output protection and object-only fetching. After source-tree
  cleanup, immutable `nix flake check` passed again in 2m01s. Native finalization
  also passed its compiler/runtime fixpoints and C/numeric/diagnostic tests;
  all seven shipped compiler/runtime files matched the accepted build exactly.
- **Source integrity:** patches apply only to private exports; original
  checkouts are unchanged.
  Licenses and runtime limitations are documented in README/DEPENDENCIES.

This is a working bootstrap toolchain with a limited bootstrap libc, **not**
a claim of complete ISO/POSIX libc or universally correctly rounded conversion.

## Evidence locations

- Fresh build: `/tmp/qfitzah-blynn-e2e`
- Immutable recipe snapshot: `/tmp/qfitzah-blynn-e2e-source.ZnHf9q`
- Task: `bg_8g9v_mv2lwv70_172` (succeeded); 15-minute watcher stopped afterward
- Full log: `/tmp/pi-better-background-tasks/tasks/bg_8g9v_mv2lwv70_172/output.log`
- Execution trace: `/tmp/qfitzah-blynn-e2e.execve`
- In the fresh build: `timing.json`, `phases.tsv`, `audit.json`,
  `recipe.sha256`, `toolchain.sha256`, the three `*cross-build-reproducibility.txt`
  records, and `tcc/final/fixpoints.sha256`
- Independent final prefix: `/tmp/qfitzah-blynn-tcc-final-checked`

`audit-build.py` verified all recorded artifact/recipe hashes, timing, phases,
static ELF/runtime metadata, executable-path categories and final independent
outputs. Source/working-directory review supplements that automated check.

## Reproduce and use

```sh
bash bootstrap/blynn/fetch.sh /tmp/blynn-sources
bash bootstrap/build-blynn.sh result/bin/qfitzah /tmp/blynn-sources /tmp/new-blynn-build
/tmp/new-blynn-build/tcc/final/bin/tcc -B /tmp/new-blynn-build/tcc/final/lib \
  -static program.c -o program
```

The output directory must not exist. Fetching source objects beforehand is
allowed; compiler/runtime outputs must be fresh. The supplied seed must match
the recorded boundary hash. See README for individual stage interfaces.
