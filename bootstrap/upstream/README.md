# Upstream source inputs (work in progress)

`bash bootstrap/upstream/fetch.sh CACHE` fetches and verifies source archives;
existing cache entries are verified too. This is acquisition only; build recipes
and their validation status are described below.
No archive contents are executed by this script. Network access is confined to
this acquisition step. The compiler path must not depend on host Guile, GCC,
TCC, or precompiled parser tables.

The initial i386 target uses:

| Source | Purpose | License (see archive for per-file notices) |
| --- | --- | --- |
| GNU Mes 0.27.1 | MesCC Scheme compiler, Scheme compatibility libraries, Mes libc | GPL-3.0-or-later; some libc files have additional exceptions |
| Nyacc 1.00.2-lb1 | Bootstrap-adapted C parser and parser generator | LGPL-3.0-or-later, with file-specific notices |
| TCC 0.9.26-1147-gee75a10c | Jan Nieuwenhuizen's bootstrappable TCC fork | LGPL-2.1-or-later, with file-specific notices |

Exact SHA-256 hashes and URLs are in `sources.tsv`. Hashes were cross-checked
against live-bootstrap revision `b1ceced7ea8a819a26f23796f6dd7ae8496a33a4`
(`steps/mes-0.27.1/sources`, `steps/tcc-0.9.26/sources`) and all three archives
were fetched and verified. Upstream archives remain unchanged; the explicit
source preparation patches below are applied only to new working copies.

## Source preparation and local adaptations

`bash bootstrap/prepare-nyacc.sh EXTRACTED_NYACC NEW_DIRECTORY` copies the
verified source, removes all eight distributed C99/CPP parser artifacts, and
applies `patches/nyacc-mes-modules.patch` with no fuzz. It uses only file-copy,
removal and patch utilities, not a compiler or Scheme interpreter.

The one-line patch makes the CPP module's modern bitwise/pmatch imports apply
under `mes` as well as `guile-2`. Mes's flat compatibility loader normally
ignores the legacy Guile-1.8 imports in the alternative branch. Our lexical
module host instead follows imports, so that branch would incorrectly require
Guile's unavailable `ice-9 syncase` and obsolete `nyacc compat18`. The patch
changes no grammar, parser algorithm or generated data, and avoids falsely
advertising the host as Guile 2. Original copyright/license notices are retained.

All eight CPP/C99/C99x/C99cx outputs have been regenerated and pass structural
comparison. All four tables are byte-identical to the archive copies; action
formatting differs. Archive artifacts are only post-generation test oracles,
never compilation inputs. CPP, full C, C99cx and pretty-printer tests pass.

`bash bootstrap/regenerate-nyacc.sh HOST MES_SOURCE NYACC_SOURCE NEW_DIRECTORY`
is the full clean-tree recipe. It executes the three upstream generation scripts
through the source-built host, with phase instrumentation from
`bootstrap/nyacc-profile.scm`. Generation can take a long time; no host Scheme
fallback is attempted. After generation, `tests/nyacc-generated.sh HOST
MES_SOURCE ORIGINAL_NYACC GENERATED_NYACC` compares all eight files as read
Scheme datums, without evaluating the reference artifacts.

## C and libc staging recipes (not yet validated end to end)

`bootstrap/mescc.sh HOST MES_SOURCE GENERATED_NYACC -S ...` invokes upstream
MesCC with explicit source paths. The Scheme driver blocks assembly/linking
operations, including mixed command-line modes; it cannot fall back to upstream
wrappers invoking external M1/hex2 tools. `tests/mescc-c.sh` passes actual C
preprocessing, globals, calls, arrays, structures and control flow, then links
and runs exit-42 executables with the source-built M1 tool.

The driver also loads `bootstrap/mescc-fixes.scm`, explicit Scheme-level repairs
for pinned Mes 0.27.1; it does not modify the pinned tree. Reproducible-mode AST
comments reserve a text position (but emit no machine bytes), preventing an
`if` and its ternary test from reusing a control-flow label. Named declarations
are merged so tentative/extern redeclarations do not erase initializers, and
repeated string-pool keys receive one definition. Function-pointer typedefs
are registered in the type namespace rather than emitted as data objects.
`mescc-labels.c` and `tests/mescc-units.sh` exercise these cases, including shared
typedefs and indirect calls across separately compiled units.
The linker still rejects conflicting definitions; accepting them
would conceal incorrect branches or initialized data. These repairs do not
claim complete C diagnostics or fix the separate inferred-string-array-size
limitation documented in the acceptance ledger.

`bootstrap/prepare-mes-libc.sh MES_SOURCE NEW_DIRECTORY` copies the source and
creates the minimal `include/mes/config.h` and Linux/i386 `include/arch` headers
used by the bootstrap. `bootstrap/build-mes-libc.sh {mini|tcc} HOST MES_SOURCE
GENERATED_NYACC NEW_DIRECTORY` selects the manifests in `bootstrap/mes-libc/`,
including GNU Mes's C crt1. `build-mes-libc-mini.sh` is a convenience wrapper.
The 158 unique sources in both manifests match the pinned upstream recipe's
crt1, libmescc, libc and libc+tcc source lists. `tests/mescc-libc-mini.sh` checks
arguments, environment, strings and output. The first compilation reached M1
string emission and exposed missing `last`, now implemented; complete libc
compilation succeeded on retry, but independent linking exposed undefined
`write`. `bootstrap/mes-libc/mini-write.c` supplies a source-compiled,
bufferless errno-aware adapter for the mini-only probe. Full libc uses upstream
`lib/posix/write.c`, not this adapter. Linked mini execution now passes argc/argv,
envp/environ, strlen, puts and EBADF/errno tests. Full libc compilation to M1
also succeeded; a checkpoint-recovery build now links and executes TCC against
it and completes later TCC-built libc and compiler fixpoints.

`bootstrap/prepare-tcc.sh TCC_SOURCE NEW_DIRECTORY` creates a compiler-flag-based
configuration header and applies `patches/tcc-ar-open.patch`. This combines
live-bootstrap's `remove-fileopen` and `addback-fileopen` patches: archive output
is opened after input processing rather than before it. Preparation and reverse
patch checks pass, and the pinned source tree is unchanged. TCC compilation
and self-rebuild now pass through checkpoint recovery. Earlier attempts
exhausted the 128 MiB heap after about 15 hours. The 512 MiB retry passed host/C regressions
and parsed TCC, but also exhausted memory during early function compilation.
Diagnosis confirmed fragmentation: only 38,208 contiguous bytes remained for
a 65,536-byte pointer table despite ~10 MiB retained in a 512 MiB heap. The
current host divides that same total object budget into 256 MiB small/large
arenas. Source-built checkpoint replay now reaches tested executable TCC;
libc, Nyacc and failed-generation outputs are preserved. `bootstrap/build-tcc-mes.sh HOST M1_LINK
MES_SOURCE GENERATED_NYACC TCC_SOURCE BUILT_LIBC_TCC NEW_DIRECTORY` stages the
first source-only MesCC/M1 build. It does not perform the later TCC-built libc
or TCC self-rebuild and is not yet an end-to-end verified recipe. An optional
final `--from-ast` resumes backend work in an existing build directory: it
requires `tcc.E`, its completion marker and the prepared source, and refuses to
overwrite existing `tcc.M1`. The default fresh recipe still parses C from source;
checkpoint replay does not establish a fresh end-to-end reproduction.

`bootstrap/build-tcc-libc.sh` builds a TCC libc from the 258-source manifest,
using only that TCC for compilation, assembly and archive creation. The explicit
`--bootstrap-runtime` mode uses Mes's limited helpers. The default instead builds
TCC's `lib/libtcc1.c`, `alloca86.S` and `alloca86-bt.S` from `PREFIX/source`.
Bounds-checking instrumentation is not enabled or claimed.

The TCC-built libc substitutes `bootstrap/mes-libc/abtod.c` for Mes's original
converter (GPL-3.0-or-later; its license is in `bootstrap/mes-libc/COPYING`):
the latter divides all fractional digits by only one radix and
accumulates integral digits through 32-bit `long`. The replacement handles the
tested numeric subset, including signs, fractions, decimal/hex exponents and
end pointers. It is **not** a fully correctly-rounded, locale-aware `strtod`;
Infinity/NaN spellings and extreme mantissa/exponent cancellation remain outside
coverage. Pinned and prepared upstream source files stay untouched.

`bootstrap/rebuild-tcc.sh INITIAL_TCC_BUILD BUILT_MES_LIBC_TCC` first converges
boot0..boot3 with bootstrap helpers, then promotes to the full runtime and
requires full1/full2 compiler and runtime byte fixpoints at fixed source paths.
`tests/tcc.sh` checks wide signed/unsigned division, shifts, conversions, IEEE
word oracles, variable-length stack arrays, ABI, allocation, files, repeated
binary output and invalid-C diagnostics. These checks now pass on the recovered
source-built compiler. `bootstrap/build-tcc.sh SEED VERIFIED_MES_SOURCE
VERIFIED_NYACC_SOURCE VERIFIED_TCC_SOURCE NEW_DIRECTORY` stages the combined
recipe, copying the seed and recipe files into its output tree before executing
and checking compiler/runtime fixpoints. A successful fresh combined run under
four hours remains unverified; checkpoint recovery does not satisfy that target.

## Requirements identified from upstream recipes

- MesCC runs Scheme sources in `module/mescc` plus Nyacc and Mes libraries.
  Guile module declarations have Mes alternatives, but Mes compatibility also
  requires procedural macros, file/string ports, records, exceptions and
  integer/bit operations. `bootstrap/mes-host/` supplies these beyond the core
  rsc subset; integration coverage is recorded in `BOOTSTRAP-PLAN.md`.
- Nyacc's generated `mach.d/*-{act,tab}.scm` files must be regenerated from
  grammar sources with the bootstrapped Scheme environment, not silently
  accepted as trusted generated inputs. Upstream scripts are
  `gen-cpp-files.scm`, `gen-c99-files.scm`, and `gen-c99cx-files.scm`.
- MesCC emits M1 assembly. Its assembly/linking tools must also come through
  the source bootstrap, or be replaced by a source-built compatible stage.
- TCC initially uses Mes libc and the bootstrap configuration (`BOOTSTRAP`,
  `CONFIG_TCCBOOT`, `ONE_SOURCE`, `HAVE_LONG_LONG=0` on i386). Upstream then
  recompiles libc and TCC to enable the full compiler. A `-version` check alone
  is not a completion criterion.

This project retains the existing explicitly documented GNU-binutils-built
qfitzah seed. Host shell, file utilities, downloading and archive extraction
are orchestration, not permission to introduce a host compiler downstream.
