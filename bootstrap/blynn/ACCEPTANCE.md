# Fresh Blynn/TCC bootstrap acceptance

Verified on 2026-10-10 against `siraben/blynn-bootstrap` commit
`db5fe7b533f67da246164d0e9017346fea821631`.

## Result and measurement conditions

**Fresh complete build, audit and independent comparisons: 13m28.310s wall.**
The recipe's `/proc/uptime` measurement was **808.03 seconds**, below the
**1,800-second limit**. Every compiler stage, native runtime rebuild and in-recipe
test ran fresh. This was not checkpoint recovery or a cached Nix build.

Machine: AMD Ryzen 9 5950X, 125 GiB RAM, amd64 Linux with i386 execution support.
The output and private temporary files used executable **tmpfs (`/dev/shm`)**.
Pinned source Git objects were already available; no generated compiler artifact
was reused. Execution tracing used `strace --seccomp-bpf -f` to observe only
`execve`/`execveat` without trapping every byte-oriented read/write.

| Recipe phase | Seconds |
|---|---:|
| Verify pinned source objects | 0.06 |
| qfitzah/Scheme → hex0 → stage0/M2, including bridge tests | 25.38 |
| Both singularity compiler lineages and unit tests | 5.50 |
| Source-entry root Blynn ladder and VM tests | 300.27 |
| Current Blynn and HCC | 373.18 |
| HCC → TCC, native runtime/compiler rebuilds and tests | 103.42 |

Small orchestration/hash overhead accounts for the remainder. Storage and
observation conditions matter: a controlled compilation took 0.184s on tmpfs,
0.202s with filtered tracing, but exceeded 30s on the then-stalled disk-backed
filesystem. Earlier misconfigured/stalled attempts were rejected, not counted
as acceptance. Do not attribute the entire improvement over the earlier
24-minute run to compiler simplification or promise this timing on every host.

Final compiler: **TinyCC 0.9.28-unstable-2025-12-03**, static ELF64 amd64.
SHA256: `a0f2cf6210f0092c17a5b7bbc831e91705300cee3ddb407aafd2b38c3bd83cf5`.

## Requirement audit

- **Route:** qfitzah → Scheme → stage0/M2 → source-entry Blynn → current
  Blynn/HCC → TinyCC. All phases passed.
- **Seed:** the sole executable compiler seed is 2,544 bytes, SHA256
  `abd1975d1145c4ed808b2cac6e2265df958f1052a6b459b28664bcbcde8906aa`.
  No host compiler, assembler, linker, archiver or additional executable seed
  was used downstream. Host shell/file tools remain declared orchestration
  dependencies, not a claim of a fully bootstrapped host OS.
- **Sources:** commit/tree pins are checked through private object-only Git
  views. Mutable worktrees, replacement refs and local archive attributes do
  not select compiler inputs. The build uses one read-only recipe snapshot;
  all 181 recipe-file hashes were rechecked.
- **Regeneration:** imported seed directories and the starting `blob/` are
  absent. The initial combinator image comes from high-level source and
  reproduces itself. Later images, generated C, M1, executables, runtime
  objects and archives are regenerated.
- **Libc boundary:** runtime libraries and startup code are source-built, not
  host libc/compiler-runtime inputs. All 64 retained executables (9 i386,
  55 amd64) lack `PT_INTERP` and `PT_DYNAMIC`.
- **Correctness:** C/ABI, wide integer and floating arithmetic/conversion,
  VLAs, allocation, file I/O and repeated-output probes passed. Invalid syntax
  and duplicate strong symbols failed without publishing output. The complete
  build log contains no error/fatal/FAIL diagnostics; upstream warnings are not
  standards-conformance evidence.
- **Fixpoints:** initial TCC stage 2 equals stage 3. Native compiler/runtime
  rounds b and c match; the observer checks actual bytes as well as all 22
  fixpoint-manifest entries.
- **Independent equality:** all 15 root/current Blynn and HCC executables match
  the previous independent build. Final TCC and all six shipped runtime files
  also match. Archive timestamps are zero; build prefixes are absent. The
  byte-identical final toolchain had also passed relocation tests.
- **Regression coverage:** the final immutable source suite passed in 1m20s.
  Source-boundary tests include mutable configuration/attribute injection.
  Seven observer test groups pass normally and under Python optimization,
  covering ELF linkage, manifest/fixpoint corruption, completion flags, time
  limits, archives and forbidden executable paths. A failed `ENOENT` search for an
  approved host tool is recorded separately, never treated as an execution.

The compiler/build implementation is 187 lines smaller than the pre-audit PR,
excluding documentation and the observer. Specialized Scheme calls, frame
construction and native list/environment searches were removed; semantic tests
remain. Safety checks, useful runtime features and optimizations in the dominant
upstream stages were retained. See [DEPENDENCIES.md](DEPENDENCIES.md).

This is a limited bootstrap libc, not complete ISO/POSIX coverage or a universally
correctly rounded floating converter. Source notices and licenses are retained.

## Evidence and reproduction

Local evidence (not compiler inputs):

- Workspace: `/dev/shm/qfitzah-simplified-final.n9858e`
- Preserved workspace: `/tmp/qfitzah-simplified-final.n9858e.tar` and `.tar.sha256`
- Frozen source: `source/`; fresh output: `build/`
- `run.sh`, `outer-seconds`, `execve.log`, `result.json`
- In `build/`: `timing.json`, `phases.tsv`, `audit.json`, `recipe.sha256`,
  `toolchain.sha256`, `independent-compilers.txt`, `tcc/final/fixpoints.sha256`
- Independent reference: `/tmp/qfitzah-blynn-e2e`
- Full run log: `/tmp/pi-better-background-tasks/tasks/bg_8g9v_mv2w7urj_188/output.log`

```sh
bash bootstrap/blynn/fetch.sh /tmp/blynn-sources
workspace=$(mktemp -d /dev/shm/qfitzah-build.XXXXXX)
strace --seccomp-bpf -f -s 4096 -e trace=execve,execveat -o "$workspace/execve.log" \
  bash bootstrap/build-blynn.sh result/bin/qfitzah /tmp/blynn-sources "$workspace/build"
"$workspace/build/tcc/final/bin/tcc" -B "$workspace/build/tcc/final/lib" \
  -static program.c -o program
```

The output directory must not already exist and the seed must match its pinned
hash. Tracing is optional. `audit-build.py BUILD TRACE INDEPENDENT_FINAL_PREFIX`
checks the completed evidence; source and relative working-directory review
supplement that automated check.
