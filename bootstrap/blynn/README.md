# qfitzah entry into blynn-bootstrap

Target source pins are in `sources.tsv`. Git exports use the pinned commit/tree
through a private object-only view, excluding mutable worktree, configuration
and archive-attribute overrides. The initial stage0 export deliberately excludes
`bootstrap-seeds`.

## Stage0/M2 entry

`build-blynn-tools.sh` builds its own Scheme stages and `hex0.scm` through rsc.
That assembler reads handwritten annotated hexadecimal source, validates it,
and writes raw bytes. It accepts hex digits, ASCII whitespace and `#`/`;` line
comments. Unlike permissive hex0 implementations, other characters and unmatched
nibbles are errors; no existing output is truncated on these errors.

The resulting AMD64 hex0 assembles itself and kaem from source. Source-built
kaem runs upstream's unchanged mini/full recipes through phase 15. Six final
tool hashes must match the pinned post-generation answer file. Host shell, Git,
tar, hashing and file utilities orchestrate or validate only.

## Blynn source entry

The stock root ladder consumes `blob/*.source` compiled combinator programs.
We instead compile the pinned `singularity` high-level source with a small
rsc-built compiler, and enter the existing ladder at its self-compilation step.
The prepared root tree has `blob/` removed to prevent accidental dependence.

The compiler is split into a lexer/parser, bracket abstraction/emitter, and
entry point. Its language has lowercase ASCII names, application, parentheses,
lambdas and function parameters, raw `@` primitives, `#` character bytes, and
`--` comments. It uses classic SKI abstraction, with no eta optimization, to
match the algorithm in Ben Lynn's `singularity`. Global ION byte references
limit a program to 224 definitions. This is not a general Haskell compiler.

Duplicate definitions, unbound variables, forward/self global references and
parse errors are rejected before emission. The VM's global table is populated
sequentially; source recursion uses explicit `@Y`. Tests cover the 224-definition
limit and byte-valued indices. Raw `@` primitives are intentional VM escapes,
not a claim that arbitrary opcode bytes form valid executable programs.
Tests cover independent small programs and source compiler self-reproduction.
The 4,573-byte compiled `singularity` must reproduce itself under the
qfitzah/M2-built VM; both rsc lineages must also produce identical compilers.

`build-blynn-root.sh` applies the target's pinned patch series to fresh source
exports. An additional `vm-buffer-end.patch` moves buffer-end initialization
after allocation, checks raw input capacity, and appends its NUL terminator.
Previously the end pointer was computed from an uninitialized global pointer;
its output overflow check therefore did not bound the allocated buffer.
Original source checkouts and their copyright/license notices remain untouched.

## Current compiler and HCC

`build-blynn-hcc.sh` verifies the root/tools hashes, exports the pinned current
compiler and target, then uses the target's portable compiler, object-IR and
C-generation scripts. HCC's backend is explicitly M2, never the host-compiler
or prebuilt-TCC alternatives. M2 temporary files have a private directory.
All builders use stage0's pinned M2libc (`68a23cfd...`); the target's other two
M2libc revisions are not build inputs.

The target's compiler patches contain stale or asymmetric context. Local
`local-patch-context.patch`, `runtime-patch-context.patch` and the replacement
`crossly-perf-context.patch` repair context/metadata without changing the
intended substitutions. The full series now applies without fuzz; its result
was compared with a separately applied reference series. Repairs affect fresh
exports only.

`prepare-blynn-tcc.sh` exports TinyCC and bootstrap libc sources, applies the
target's patches and assembles libc source. `configure-lib.sh` only enumerates
files: its `compiler=gcc` selects GNU assembly syntax for TinyCC, not a GCC
execution. The HCC-built TinyCC must pass a native stage-2/stage-3 fixpoint
and an executable smoke test.

`build-blynn-tcc.sh` requests the upstream self-rebuild, then
`finalize-blynn-tcc.sh` rebuilds the native compiler and complete bootstrap
runtime through three rounds and runs independent C/numeric tests. Finalization
uses the source repair in `bootstrap/blynn/libc/abtod.c`. Its locale-independent
conversion subset is not universally correctly rounded, does not support all
Infinity/NaN spellings or extreme mantissa/exponent cancellation, and `strtold`
still narrows through double precision. The libc also retains upstream stubs;
this is not a complete ISO/POSIX libc. Licenses and source notices are retained.

`tcc-relative-include.patch` makes the compiled include path `{B}/../include`,
not an absolute build-directory path. Relative native source filenames also
avoid embedding the build prefix through `__FILE__`. Native finalization excludes
the heap-based `alloca`, using TinyCC's
own assembly implementation instead. A minimal `tcc-driver-errors.patch` stops
object-loading errors from being erased by the output API: duplicate strong
symbols must fail without publishing an executable, not merely print an error.

See [ACCEPTANCE.md](ACCEPTANCE.md) for measured end-to-end timing, compiler/runtime
fixpoints, independent output comparisons and the requirement audit. Stage
measurements or recovered component builds do not count as fresh acceptance.

## Interfaces

```
bootstrap/blynn/fetch.sh SOURCE_CACHE
bootstrap/build-blynn.sh TRUSTED_SEED SOURCE_CACHE NEW_DIRECTORY
bootstrap/build-blynn-tools.sh SEED SOURCE_CACHE NEW_DIRECTORY
bootstrap/build-singularity.sh SEED RSC_COMPILER NEW_DIRECTORY
bootstrap/build-blynn-root.sh QFITZAH_TOOLS SINGULARITY_COMPILER SOURCE_CACHE NEW_DIRECTORY
bootstrap/build-blynn-hcc.sh QFITZAH_TOOLS BLYNN_ROOT SOURCE_CACHE NEW_DIRECTORY
bootstrap/prepare-blynn-tcc.sh SOURCE_CACHE NEW_DIRECTORY
bootstrap/build-blynn-tcc.sh QFITZAH_TOOLS BLYNN_HCC SOURCE_CACHE NEW_DIRECTORY
bootstrap/finalize-blynn-tcc.sh HCC_TCC_TREE PREPARED_SOURCES NEW_DIRECTORY
```

The complete recipe rejects an existing output directory and any seed that does
not match `seed.sha256`. It clears inherited build overrides, guards host compiler
fallback names, makes one read-only recipe snapshot, records source hashes and
uses `/proc/uptime` for phase/total timing. Every component uses that snapshot;
the hashes are verified again after building. Direct component invocations use
the caller's source tree, so use an immutable checkout when measuring them.

The acceptance limit is **30 minutes**. The driver lets an over-budget build
finish, then reports failure rather than killing useful work. `timing.json`
distinguishes completion from successful fresh-under-limit acceptance. Source
Git objects may be fetched beforehand; no generated artifact is reused.

These byte-oriented tools can be sensitive to filesystem latency. For consistent
measurements, use fast scratch storage. On Linux with executable tmpfs and
sufficient free RAM, for example:

```sh
workspace=$(mktemp -d /dev/shm/qfitzah-build.XXXXXX)
bash bootstrap/build-blynn.sh result/bin/qfitzah SOURCE_CACHE "$workspace/build"
```

The acceptance report records the actual machine and storage used; the time
limit is not a performance guarantee for every host or filesystem.

For optional execution tracing, use kernel-side syscall filtering:

```sh
strace --seccomp-bpf -f -s 4096 -e trace=execve,execveat -o build.execve \
  bash bootstrap/build-blynn.sh SEED SOURCE_CACHE NEW_DIRECTORY
```

Using only `-e trace=...` still intercepts every syscall and can dominate runtime
for these byte-oriented tools. Do not compare such timings with the filtered
trace or an untraced build. Tracing is observation, not a compiler dependency.

Use the final compiler with its own runtime:

```
BUILD/tcc/final/bin/tcc -B BUILD/tcc/final/lib -static program.c -o program
```

See [DEPENDENCIES.md](DEPENDENCIES.md) for the source-boundary/license audit.
