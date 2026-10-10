# Fresh Blynn/TCC bootstrap acceptance

Verified on 2026-10-10 on SSH host `compute`, using qfitzah commit
`26e2a2c35f4db3e427599e344688e44b1c755d45` and `siraben/blynn-bootstrap` commit
`db5fe7b533f67da246164d0e9017346fea821631`.

## Result and measurement conditions

**Fresh complete build, audit and independent comparisons: 19m18.234s wall.**
The recipe's `/proc/uptime` measurement was **1,157.82 seconds**, below the
**1,800-second limit**. Every compiler stage, native runtime rebuild and in-recipe
test ran fresh. This was not checkpoint recovery or a cached Nix build.

Machine: **8 AMD EPYC-Milan vCPUs (KVM), 30 GiB RAM**, amd64 Linux with i386
execution support. Output and private temporary files used ordinary **ext4 on
`/dev/sda1`**, under the user's home directory. No tmpfs or RAM disk was used for
build/scratch files; ordinary OS filesystem caching was not disabled.

Pinned source Git objects were preloaded. No generated compiler artifact was
reused as a build input. Independent reference hashes and non-executable runtime
files were supplied solely for post-build comparison. Execution tracing used
`strace --seccomp-bpf -f` to observe `execve`/`execveat` without trapping every
byte-oriented read/write. Build, audit and comparison exit statuses were all 0.

| Recipe phase | Seconds |
|---|---:|
| Verify pinned source objects | 0.13 |
| qfitzah/Scheme → hex0 → stage0/M2, including bridge tests | 49.21 |
| Both singularity compiler lineages and unit tests | 11.37 |
| Source-entry root Blynn ladder and VM tests | 418.65 |
| Current Blynn and HCC | 529.18 |
| HCC → TCC, native runtime/compiler rebuilds and tests | 148.87 |

Small orchestration/hash overhead accounts for the remainder. The earlier local
Ryzen 9 5950X/tmpfs run passed in 13m28.310s, but the disk-backed `compute` result
above is the primary timing. Different hardware/storage prevents attributing the
wall-time difference to compiler changes. This is not a timing guarantee for
every host. The remote supervision wrapper encountered a zsh compatibility error;
the original build continued uninterrupted and its own completion/timing files
were collected through an independent watcher.

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
- **Regression coverage:** separately, the same compiler/test sources passed the
  full local regression suite in 1m20s.
  Source-boundary tests include mutable configuration/attribute injection.
  Seven observer test groups pass normally and under Python optimization,
  covering ELF linkage, manifest/fixpoint corruption, completion flags, time
  limits, archives and forbidden executable paths. A failed `ENOENT` search for an
  approved host tool is recorded separately, never treated as an execution.

At the measured revision, compiler/build sources were 187 lines smaller than
in the pre-audit PR, excluding documentation and the observer. Specialized Scheme calls, frame
construction and native list/environment searches were removed; semantic tests
remain. Safety checks, useful runtime features and optimizations in the dominant
upstream stages were retained. See [DEPENDENCIES.md](DEPENDENCIES.md).

This is a limited bootstrap libc, not complete ISO/POSIX coverage or a universally
correctly rounded floating converter. Source notices and licenses are retained.

### Source-commentary follow-up

The later in-source walkthroughs change no non-comment executable lines. They
explain the reader/interpreter handoff, native calling convention, assembler
passes and SKI lowering without adding a documentation-generation dependency.
The reading route is in [ARCHITECTURE.md](../../ARCHITECTURE.md).

Validation on disk-backed `compute` passed in **228.807 seconds**: regenerate
Scheme compiler stages, hex0, all six stage0 tools and both singularity compiler
lineages; compare their assembly/executables and the starting combinator images
with the timed build; run VM/self-compilation checks, full source regressions,
source-boundary tests and observer tests (including Python optimization).
This is a commentary regression check, not a new full-chain timing measurement.

Evidence: `compute:/home/siraben/qfitzah-commentary.YcNt77/{source,check.sh,result.json}`
and local log
`/tmp/pi-better-background-tasks/tasks/bg_8g9v_mv31son2_194/output.log`.

## Evidence and reproduction

Evidence (not compiler inputs):

- Remote workspace: `compute:/home/siraben/qfitzah-disk-timing.3FVaIk`
- Frozen source: `source/`; fresh output: `build/`
- `host.txt`, `source-commit`, `run.sh`, `started-utc`, `outer-seconds`,
  `execve.log`, `result.json`, `verification.json`, `audit.json`,
  `independent-compilers.txt`, `reference-programs.sha256`
- In `build/`: `timing.json`, `phases.tsv`, `recipe.sha256`, `toolchain.sha256`,
  `recipe-verified.log`, `tcc/final/fixpoints.sha256`
- Remote full run log: `/tmp/pi-bg-bg_8g9v_mv2xbidy_191.log`
- Local evidence copy: `/tmp/qfitzah-compute-evidence.BZAfka` and `.sha256` manifest
- Independent reference origin: `/tmp/qfitzah-blynn-e2e` on the local host
- Earlier local workspace archive: `/tmp/qfitzah-simplified-final.n9858e.tar`

```sh
bash bootstrap/blynn/fetch.sh /tmp/blynn-sources
workspace=$(mktemp -d "$HOME/qfitzah-build.XXXXXX")
findmnt -T "$workspace" # Check that this is ordinary disk-backed storage.
strace --seccomp-bpf -f -s 4096 -e trace=execve,execveat -o "$workspace/execve.log" \
  bash bootstrap/build-blynn.sh result/bin/qfitzah /tmp/blynn-sources "$workspace/build"
"$workspace/build/tcc/final/bin/tcc" -B "$workspace/build/tcc/final/lib" \
  -static program.c -o program
```

The output directory must not already exist and the seed must match its pinned
hash. Tracing is optional. `audit-build.py BUILD TRACE INDEPENDENT_FINAL_PREFIX`
checks the completed evidence; source and relative working-directory review
supplement that automated check.
