# MesCC → TCC implementation ledger (historical)

**Retargeted by the user on 2026-10-10.** The MesCC build and its monitor were
stopped; all artifacts remain preserved. Task 155 was cancelled at approximately
208m17s, not completed. The active target is now Blynn/HCC → TCC; see
[BLYNN-BOOTSTRAP-PLAN.md](BLYNN-BOOTSTRAP-PLAN.md). The entries below describe the
previous route and do not authorize continuing it.

## Acceptance criteria

- A reproducible source-only chain from the existing qfitzah seed through the
  Scheme stages to MesCC and a working TCC; no host Scheme or C compiler in
  this dependency path.
- Pinned upstream source versions, hashes, licenses, and documented local
  adaptations. Host fetching/unpacking/orchestration are distinguished from
  compilation dependencies.
- Required Scheme semantics and runtime facilities tested independently,
  including reclamation and allocation failure behavior for large workloads.
- TCC compiles and runs C probes and rebuilds itself; bootstrap fixpoints and
  existing tests remain checked.
- Small, named compiler/runtime helpers rather than increasingly monolithic
  dispatch functions; runtime representations and root invariants documented.

## Milestones

1. **Baseline and initial source audit done:** artifacts built from the seed;
   Mes 0.27.1, Nyacc 1.00.2-lb1 and bootstrap TCC archives pinned and verified.
   Detailed compatibility auditing continues as stages are exercised.
2. **Base support implemented/tested:** collecting runtimes, ports, continuations,
   exact integers, reader, modules and macros; frontend compatibility fixes continue.
3. **C probes pass:** pinned MesCC runs on the source-built host and links through
   the source-built M1 tool. Fresh-recipe Nyacc reproduction also passed:
   all eight files reproduced byte-for-byte, with parser execution checks.
4. Build Mes libc and bootstrap TCC, then verify C compilation and self-rebuild.
5. Integrate reproducible build/check targets, document trust boundary, and
   audit every acceptance criterion.

## Evidence and open issues

- Initial checkout: `a1e26b1`; working tree clean before this effort.
- Existing chain ends at `rsc`; no Mes, MesCC, Nyacc or TCC sources/recipes.
- Existing runtimes use unchecked fixed arenas, with no garbage collection.
- `ARCHITECTURE.md` records semantic bugs; self-hosting alone does not certify
  sufficient Scheme compatibility.
- `bootstrap/upstream/` records source hashes, acquisition and upstream recipe
  requirements. All three pinned source downloads verified successfully.
- Baseline artifacts built successfully in `/tmp/qfitzah-mes-baseline`.
- First rsc repairs: full-width fixnum literal emission, lexical internal
  definitions, test-only cond clauses, tail and/or, and non-mutating apply
  argument binding. `tests/cases/rsc-core-regressions.scm` covers them.
- `bash tests/run.sh result/bin/qfitzah` passed after these repairs (including
  full ELF fixpoints and the new corpus through both compiler lineages).
- Implemented `bootstrap/gc.qf1`: a nonmoving conservative collector with
  owner metadata, bounded worklist, reusable byte/vector storage, coalescing
  free blocks and explicit failure. rsc allocation sites now use it.
- Added `tests/runtime-memory.sh` and `rsc-gc.scm`: forced 64 KiB heap,
  cycles/closures/static roots/vector buffers, and invalid/live-exhaustion
  allocation failures. The full suite passed with both compiler lineages,
  including these tests, in 34 seconds (background run `bg_8g9v_muxkke3w_6`).
- First GC suite attempt stopped at the source-macro primitive-count oracle
  (two new primitives); updated that exact expected count and reran.
- OS I/O and port tests passed, including binary files across buffer boundaries,
  argv/environment access, string ports, printing and syscall errors.
- Native multi-shot continuations plus Scheme dynamic-wind, multiple values,
  catch/throw and fluid bindings passed 64 KiB heap tests and the full suite
  (`bg_8g9v_muxl0dx6_10`, 44 seconds).
- Added exact-integer Scheme library (base-2^14 limbs, signed division, bitwise
  operations). Wide-value oracles and signed arithmetic identities passed with
  a 256 KiB heap (`bg_8g9v_muxl6vmi_11`).
- Port-aware reader and reader/writer roundtrip/rejection tests pass after
  fixing vertical-bar escaping. Full suite passed (`bg_8g9v_muxleehk_13`, 60s).
- Added decomposed Mes-host evaluator sources: lexical cells/environments,
  syntax handlers, procedural macros, eval/load, keyword arguments and promises.
  They compile to qfasm, but their larger assembly hit the seed's old 1.5 GiB
  unchecked arena. A 64 MiB stack did not help; strace reports fault address
  `0x6b54a000`, the first page beyond the seed's load segment.
- Implemented separate `bootstrap/seed-gc.s` for the existing seed: fixed-cell
  conservative marking, atom-table/global/stack roots, weak memo invalidation
  and checked exhaustion. Instrumented 256 KiB seed tests passed, including
  repeated reuse, persistent rules and live OOM (`bg_8g9v_muxm4prx_19`).
  Seed grows from 2,148 to 2,544 bytes and defaults to a 256 MiB cell arena.
  This retains the documented binutils seed build, not a host compiler escape
  hatch. `flake.nix` includes its source and a `seed-memory` check.
- Full suite with the collecting seed passed (`bg_8g9v_muxm5xiw_21`), as did
  Mes-host evaluator/derived syntax tests (`bg_8g9v_muxm5v0p_20`). The Mes-host
  test is now integrated in `tests/run.sh` for both compiler lineages.
- Added lexical source modules with shared import cells, selected/prefixed
  imports, circular dependencies, separate Mes macro/value namespaces and
  typed vector records. Local module/record fixtures passed with the initial
  modular host in `/tmp/qfitzah-host-modules`.
- Loaded pinned Mes's actual `mes/syntax.scm` and used its source syntax-rules
  compiler to expand an ellipsis macro (result 6, `bg_8g9v_muxmkdbj_22`).
  Definition-site explicit-renaming identifiers now pass capture, literal
  binding, nested ellipsis, vector, quotation, private helper and local macro
  tests (`bg_8g9v_muxnc4tt_26`).
- Added a native uninterned-symbol constructor for genuine gensym identity;
  the source bootstrap/fixpoints passed (`bg_8g9v_muxmnd78_23`). New verified
  compiler artifacts are in `/tmp/qfitzah-mes-symbols`.
- Actual `(mescc info)` import and operations now pass (`bg_8g9v_muxnc4tt_26`):
  constructors, type discrimination, immutable pointer updates, keyword-based
  cloning and multi-field updates. Fixed legacy `:export` handling and supplied
  lexical current-environment plus Mes-compatible ignored procedure metadata.
  `tests/mes-upstream.sh HOST MES_ROOT` runs this pinned-source integration suite.
- Full regression suite with module/identifier tests passed
  (`bg_8g9v_muxnf1bl_27`, 88 seconds). Subsequent compatibility changes need a
  fresh full run; this evidence is not a final completion audit.
- Nyacc CPP grammar imports now traverse LALR, SRFI-1/43, pretty-print, parse
  and lex modules. Added core snapshots, Mes-shaped native character sets,
  formatting and private procedural-macro fallbacks. The latest load stopped
  at legacy control-character names in lex.scm (`bg_8g9v_muxo5g67_31`); aliases
  have been added and need a retry.
- Mes-source mode explicitly follows pinned reader/evaluator semantics for
  empty-headed dotted lists and extra if alternatives; strict defaults remain.
- Nix rebuilt the installed collecting seed and its seed-memory check; corrected
  the smoke fixture filename and all checks passed (`bg_8g9v_muxnx81n_30`).
  `result/bin/qfitzah` now matches the tested 2,544-byte
  `/tmp/qfitzah-gc-stripped` byte-for-byte (SHA256 abd1975d1145c4ed808b2cac6e2265df958f1052a6b459b28664bcbcde8906aa).
- Full immutable Nix checks passed (`bg_8g9v_muxohbag_33`, 94 seconds), including
  cell ownership, core-module isolation, compiler-phase and library tests.
- The 117k-line host exceeded the interactive seed process's 8 MiB traversal
  stack, although Nix checks passed. A controlled 64 MiB retry passed upstream
  tests (`bg_8g9v_muxoj12p_35`). The assembly driver now sets this soft limit
  locally; its output was byte-identical (`bg_8g9v_muxom7y8_37`).
- Nyacc CPP machine construction now succeeds (`bg_8g9v_muxos0b3_38`, 4m15s).
  An independent tiny grammar also constructed successfully (`bg_8g9v_muxowq0e_39`).
  Phase profiling recorded 3,008 collections during real CPP construction,
  exercising the collector well beyond small synthetic tests.
- Added `bootstrap/prepare-nyacc.sh`: copies verified source and removes all
  eight distributed C99/CPP action/table files before generation. CPP generation
  from that clean tree passed (`bg_8g9v_muxp9zrl_41`, 4m15s): cpp-tab.scm is
  byte-identical to upstream (d894fbb079cb150038e7f7057711cd601299b2099343dfae9ead409cbb90292a).
  cpp-act.scm differs only in printing; `tests/compare-scheme-source.scm`
  confirmed identical source datums without evaluating either comparison input.
- Host `/tmp/qfitzah-host-nyacc6/mes-host` passed upstream syntax/records
  and module/library tests (`bg_8g9v_muxpjpoa_42`). Core primitive import cells
  now preserve literal-binding identity, and duplicate macro fallback branches
  are avoided. String/path emitters and fluid procedure adapters were added.
- C99/C99x generation reached `(nyacc lang sx-util)` and required case-lambda
  (`bg_8g9v_muxpqn43_43`). Added a small arity-selecting handler and focused
  fixed/rest/no-match tests. Full Nix regression check passed
  (`bg_8g9v_muxpubpc_45`, 95 seconds). The C99 retry then reached Nyacc's
  legacy Guile-1.8 import branch and failed on `ice-9 syncase`.
- Added a documented one-line source-preparation patch: CPP uses its modern
  bitwise/pmatch imports under `mes`, rather than requiring Guile's obsolete
  syncase shim. The original archive is unchanged. Preparation removes all
  eight generated files and rejects already-patched input instead of reversing
  the patch. These preparation properties were tested explicitly.
- C99/C99x generation with that patch (`bg_8g9v_muxpy1ek_46`) timed out after
  60 minutes without validated output. The working tree remains
  `/tmp/qfitzah-nyacc-regenerated`; the generated CPP files are unchanged.
- The regenerated CPP parser now passes actual parsing/evaluation tests:
  precedence, signed integer division, 64-bit literals, shifts, short circuit,
  defined/undefined symbols and function-like macros (`bg_8g9v_muxqm1c0_48`).
  Host `/tmp/qfitzah-host-nyacc9/mes-host` also passed upstream syntax/records.
  Added Mes-compatible integer `/`, shift aliases and unavailable-coordinate
  port accessors (zero, matching Mes boot-03.scm); these are documented limits.
- Implemented a native source-built combined i386 M1/hex2 assembler/linker in
  `bootstrap/m1/`, with separate lexer/index, layout, relocation and CLI modules.
  `tests/m1-link.sh` passed byte oracles, all relocation widths, forward macros,
  raw quotes, alignment, checked failures and actual Linux execution. It also
  linked pinned Mes's instruction definitions and exit/hello ELF examples
  (`bg_8g9v_muxr7ov9_50`, 5 seconds). This is not yet MesCC-generated code or
  libc/TCC linking. The test is now included for both compiler lineages.
- C99 generation is slow. An identity-indexed environment experiment passed
  semantic/upstream tests with 2 MiB, but exceeded the previous 1 MiB test heap
  (`bg_8g9v_muxrydhg_52`, `bg_8g9v_muxs0ho1_53`). Worse, CPP construction took
  4m59s and 3,575 collections, versus 4m15s and 3,008 before
  (`bg_8g9v_muxsiz48_54`). **Rejected the indexed representation** and restored
  five-field alist frames. The isolated identity-hash primitive itself passed
  bootstrap and GC-stability tests and remains available.
- A traced C99 retry using the experimental binary (`bg_8g9v_muxsn0h4_55`)
  completed step1 (13,630 collections) but was still in step2 after 49 minutes.
  It was stopped before launching a replacement; no outputs from it are accepted.
- Added a smaller optimization in `bootstrap/lookup.qf1`: native, non-allocating
  `%assq`/`%memq` loops, used on private proper environment lists. Public wrappers
  retain catchable errors for malformed lists. Tests cover object identity,
  aliases, GC, absent keys and malformed input. Bootstrap and 64 KiB collector/
  control tests passed (`bg_8g9v_muxth79f_56`), but both that run and full Nix
  checks (`bg_8g9v_muxtm6ye_57`) exhausted the host's 1 MiB fixture heap even
  without indexes. Current host fixtures therefore use 2 MiB, still with a
  512 KiB stack and forced collection; this is not a claimed 1 MiB guarantee.
  New compiler artifacts are `/tmp/qfitzah-native-lookup`.
- An initial retry (`bg_8g9v_muxtx5ys_58`) encountered a shell parse error after
  its script was edited while running. Future mutable-checkout test runs use a
  copied source snapshot. Snapshot-based semantic/upstream tests passed
  (`bg_8g9v_muxu5syh_60`, host `/tmp/qfitzah-host-lookup`). CPP construction fell
  to 1m49s and 1,172 collections. Immutable full Nix checks passed too
  (`bg_8g9v_muxu1mpv_59`, 1m48s), including both compiler lineages and M1 tests.
- Restarted C99/C99x generation with the verified native-lookup host and no
  deadline (`bg_8g9v_muxuexg3_61`), which completed both machines and wrote their
  artifacts after about 127 minutes. All eight CPP/C99/C99x/C99cx files now match
  upstream as read Scheme datums, and all four tables are byte-identical.
  Hashes are recorded in `/tmp/qfitzah-nyacc-regenerated.sha256`. Independent
  C99cx generation passed in 2m55s (`bg_8g9v_muxunnpg_63`), writing different files
  in the same prepared tree. Both C99cx artifacts match the archive's read
  datums; its table is byte-identical (SHA256
  `c11b792494569232ac6de13d5d71e1e463b7cf09b147e346cfa6f04ad746fb2e`). The regenerated
  grammar executes precedence, ternary and array-reference cases successfully.
  This tests parsing, not the optional FFI-dependent `cxeval` evaluator.
- Actual MesCC backend integration now passes (`bg_8g9v_muxumfot_62`): upstream
  i386 instruction selection and info records emit M1 for a function loading a
  global integer; the source-built linker combines it with pinned Mes's full
  ELF header/footer and produces a program that exits 42. Added `negate`, tested
  with variadic predicates. `tests/mescc-backend.sh` is explicitly an IR-level
  test, not C compilation. Host/tool artifacts are `/tmp/qfitzah-host-backend`
  and `/tmp/qfitzah-m1-backend`.
- Added `bootstrap/regenerate-nyacc.sh`, a clean-tree full-generation recipe,
  and `tests/nyacc-generated.sh` for read-only structural comparisons of all
  eight outputs. The reusable phase tracer's script-argument path and shell
  syntax passed smoke checks. A fresh invocation plus byte-for-byte reproduction
  against the already generated set passed as `bg_8g9v_muy2btlc_81` in
  `/tmp/qfitzah-nyacc-recipe-check` after 145 minutes: all eight outputs are
  byte-identical to the first generation, and all parser execution tests pass.
- MesCC CLI support now passes upstream getopt-long tests, including option
  values, positional arguments, `--`, and missing-value errors. Added checked
  `string-index`/`string-index-right` with character/predicate/set matching.
  The first retry exposed a native ABI crash on two-argument `substring`; the
  host now supplies a checked optional-end wrapper (also `substring/shared`).
  Added an explicit `(mes display)` standard-writer bridge rather than pretending
  to support Mes VM raw-cell inspection. Snapshot `bg_8g9v_muxvnl4a_65` passed all
  upstream, bounded host and MesCC backend tests; `/tmp/qfitzah-host-options2`
  contains that host. Nyacc's `#\nl` character alias was added afterward.
- Full immutable checks for the CLI changes and `#\nl` passed in
  `bg_8g9v_muxw2ijd_66` (1m48s). A later optimization gives `memv`/`assv` native
  identity searches for non-vector values while retaining checked numerical
  comparison for canonical vector-backed bignums. Snapshot tests passed in
  `bg_8g9v_muxwpszk_67`; CPP construction took 1m46s and 1,167 collections, a small
  improvement rather than another major speedup. Full checks with those paths
  passed in `bg_8g9v_muxx9dqj_68` (1m50s).
- Loading Nyacc's full C pretty-printer exposed the remaining `#\np` alias;
  added it and Mes's `#\linefeed`. `/tmp/qfitzah-host-c99-reader` loads and executes
  the pretty-printer. Its first test only failed our spacing expectation (the
  source explicitly renders multiplication without surrounding spaces).
  Corrected that oracle; bounded host, upstream and backend verification passed
  in snapshot `bg_8g9v_muxxov3g_70` (18s). These last aliases postdate check 68.
- Actual C-to-ELF compilation now passes (`bg_8g9v_muxzzygy_77`): command-line
  definitions and a global variable, then guarded/repeated headers, calls,
  arrays, pointers, structures and loops. Both executables exit 42. The host is
  `/tmp/qfitzah-host-c-slices/mes-host`; `tests/mescc-c.sh` uses the source-built
  M1 linker and a minimal entry stub, not a host C toolchain or prebuilt libc.
  `bootstrap/mescc.sh` requires `-S` and disables upstream external-tool paths.
- Frontend compatibility fixes include Mes-specific adapter precedence,
  `mes?`/`guile?`, `dirname`, checked string selection/filtering and source-level
  `with-fluids`. Parallel fluid value evaluation, duplicate bindings and error
  restoration pass. A first fluid test exposed a developer-side reference to
  nonexistent native `list?`; replacing it with `%reader-proper?` fixed the
  crash. Full C preprocessing/parsing/pretty-print and expression cases are now
  included in `tests/nyacc-generated.sh` and pass.
- A bounded, opt-in syntax-rules cache experiment passed lexical binding,
  mutation, macro redefinition, GC, upstream and generated-parser tests
  (`bg_8g9v_muy17szs_78`). C probes took 73.614s without it versus 71.582s with
  it. That marginal gain did not justify its extra state/complexity, so the
  experiment was removed; ordinary expansion remains in the source tree.
- GNU Mes libc preparation creates only configuration/architecture headers from
  pinned source. `bootstrap/build-mes-libc.sh` compiles `mini` or `tcc` profiles;
  the 158 unique C sources in both manifests match the pinned live-bootstrap
  crt1/libmescc/libc/libc+tcc lists. `bootstrap/build-tcc-mes.sh` stages the first
  MesCC/M1 TCC pass, not its later libc rebuild or self-rebuild. Preparation and
  patch checks pass; full compilation remains unverified.
- First libc-mini compilation reached M1 global-string emission, then failed
  on missing `last` (task 77, 8m47s overall). Added the Mes-compatible helper and
  list regressions. Snapshot `bg_8g9v_muy24xg6_80` compiled mini successfully,
  then its independent link exposed undefined `write`: upstream mini supplies
  `_write`, but its eputs/oputs now call full libc's `write`. Added a separately
  source-compiled, bufferless mini-only adapter with errno handling. The full
  profile still uses upstream POSIX write, including buffered-read coordination.
  `bg_8g9v_muy3k8uq_82` reused the valid generated M1 and compiled the adapter.
  **The mini ELF passed** argc/argv, envp/environ identity, environment contents,
  strlen, puts and EBADF/errno checks. Artifacts are in
  `/tmp/qfitzah-libc-mini-linked`. Full libc then needed `string-fold-right`.
  Added checked forward/right folds with order, bounds, empty-range and callback
  regressions. Snapshot `bg_8g9v_muy42o9x_84` passed bounded host and pinned Mes
  tests and compiled full libc to `/tmp/qfitzah-libc-tcc-first/libc+tcc.M1`
  (248,379 bytes). It then exhausted the 128 MiB heap during TCC compilation,
  after about 15 hours in that phase (17h06 overall). No TCC M1/executable was
  produced. The direct upstream CPP escape regression passed in task 85 (2s).
  Full libc linking, TCC compilation and self-rebuild remain unverified.
- Added staging scripts for TCC-built libc (258 unique upstream sources),
  boot0..boot3 rebuilds and compiler/runtime byte fixpoints. `tests/tcc.sh` checks
  32/64-bit arithmetic, doubles, variadic/indirect calls, allocation, file I/O,
  repeated binary output and syntax-error diagnostics. They have shell syntax
  checks, not successful TCC execution yet. Full immutable checks passed in
  `bg_8g9v_muy1h5r5_79` (1m47s); cache removal and the newest continuation fixture
  passed the current-source check `bg_8g9v_muy3xdvf_83` (1m51s). String folds and
  the new staging-only `bootstrap/build-tcc.sh` driver postdate that check;
  the latter snapshots the recipe, rebuilds Scheme/M1/host stages, regenerates
  Nyacc, and sequences C/libc/TCC tests, but is not yet an executed full recipe.
- Four-level pair selectors now pass bounded host tests. The new strings probe
  exposed pinned MesCC's incorrect `sizeof` for inferred string arrays; that
  upstream limitation is not repaired. The MesCC fixture uses an explicit string
  bound while the final TCC probe retains inferred-string coverage. Task 88
  passed stringification, escaped data, mutable globals and inferred integer
  arrays through actual ELF execution.
- TCC memory retry: rsc now emits `GcMemoryBytes` instead of fixed 256 MiB BSS.
  The reservation follows the selected heap; merely increasing `GcHeapBytes`
  would otherwise leave owner/work metadata outside the ELF mapping. The Mes
  host profile is 512 MiB, with 256 MiB owners and 128 MiB mark queue. Small
  semantic tests retain 2 MiB. Added a 160 MiB live-buffer/GC regression and
  a 128 MiB checked-exhaustion comparison, plus opt-in source-level MesCC
  phase/function/GC logging with output-equivalence tests.
- Snapshot task `bg_8g9v_mv0e8d2p_90` builds current rsc/host, verifies compiler
  fixpoints, the large and bounded heaps, upstream compatibility, tracing and C
  probes before retrying TCC. It preserves prior libc/Nyacc outputs and writes
  new results under `/tmp/qfitzah-tcc-mes-large`; compiler/host outputs are
  `/tmp/qfitzah-large-heap-stages` and `/tmp/qfitzah-host-large`. On success it
  continues libc/TCC self-rebuild and probes. Task 90 verified rsc B/C source
  and executable fixpoints, then hit the 120-second host-builder test deadline
  while emitting qfasm, before large-heap execution or TCC. No memory failure
  was reported in this retry. The builder now batches rsc's byte-at-a-time
  output through a copying pipe, retaining pipefail; builder test deadlines are
  600 seconds (execution deadlines unchanged). Snapshot retry
  `bg_8g9v_mv0efftz_93` reuses the verified stages and repeats all host/C checks
  before TCC. Immutable checks `bg_8g9v_mv0e8fez_91` passed in 8 minutes,
  including the large-heap regression through both compiler lineages. That
  snapshot predates output buffering; current-source follow-up
  `bg_8g9v_mv0ej4yy_95` also passed (2m48s). The old watcher was cancelled; 15-minute
  monitoring now uses `bg_8g9v_mv0eg29v_94`.
- Task 93 passed the 512/128 MiB memory comparison, all bounded/upstream host
  fixtures, trace-output equivalence and all three C-to-ELF probes, then failed
  during TCC compilation with checked OOM after 8h38 overall. The full parser
  returned at GC 9,319; AST stripping returned at GC 58,202; compilation reached
  `add32le` at GC 58,981. There is still no TCC M1/executable. The monitor was
  stopped. Another blind capacity increase is not being attempted.
- Added a private `%gc-live-units` diagnostic: explicitly collects and counts
  retained blocks (including headers/padding) in eight-byte units, without
  allocating. A native 64 KiB regression checks live data and reclamation.
  Optional `QFITZAH_MESCC_HEAP_TRACE` adds retained-space readings to phase logs.
  Snapshot `bg_8g9v_mv0x5j69_96` rebuilds/tests this diagnostic and runs twenty
  identical real C frontend operations, discarding results, on a 128 MiB host.
  Task 96 built the diagnostic and passed the existing GC corpus, but its new
  reclamation assertion failed because a scratch register still held the last
  string's raw buffer. Replacing that incidental root before the assertion
  gives baseline/held/released readings of 574/2625/578 units. Snapshot task
  `bg_8g9v_mv0x94pq_97` passed native tests and twenty real frontend iterations
  in 2m54s. Retained space stabilized at 263,790 eight-byte units (~2 MiB)
  after the first iteration, unchanged through iteration 20. Thus this small
  repeated workload does not reproduce TCC's retention pressure.
- Reproduced false retention independently in 64 KiB: store pointer-shaped
  bytes in a live string, drop the referenced vector and its 16 KiB buffer,
  and observe that both remain retained. Added an atomic flag for byte payloads
  in `gc.qf1`; string/symbol/path buffers use `AllocAtomic`, while owners still
  recognize raw/interior roots. Pointer-bearing allocations keep their normal
  tracing. The identical native fixture changes from `#f #t` before to `#t #t`
  after; existing native GC and allocation-failure tests also pass. This fixes
  that specific false-retention path, not yet a proven cure for TCC's OOM.
  Full immutable checks passed as `bg_8g9v_mv0xed6z_98` (2m49s), including
  native GC/control/ports and both compiler lineages. Snapshot
  `bg_8g9v_mv0xf43q_99` passed stage/native memory tests, twenty frontend
  iterations, upstream/tracing checks and all three C-to-ELF probes (6m01s).
  Retained space stayed at 259,310 units, versus 263,790 before: a small reduction
  on this workload, not evidence that TCC's peak-space issue is solved.
- TCC retry `bg_8g9v_mv0xqqty_100` builds a 512 MiB atomic-buffer host, tests
  checkpoint/replay output equivalence, large live buffers and upstream behavior,
  then attempts TCC and the remaining rebuild/probe sequence. New outputs are
  `/tmp/qfitzah-host-atomic-large` and `/tmp/qfitzah-tcc-mes-atomic`; stages are
  `/tmp/qfitzah-atomic-stages`. The frontend now writes `tcc.E` and, only after
  closing it, `tcc.E.complete`, preserving parsed source data before backend
  work. It refuses existing checkpoint destinations. Retained-space tracing is
  enabled for TCC; 15-minute monitoring is `bg_8g9v_mv0xr1eo_102`.
- In parallel, `bg_8g9v_mv0xquu9_101` applies the actual upstream AST normalization
  passes to synthetic broad translation units on the 128 MiB atomic host. This
  is a bounded diagnostic of transient space, not an actual C build. It reached
  its 20-minute deadline during the 1,024-declaration comment pass, without OOM.
  All four passes completed at 64/128/256/512 declarations; post-pass retained
  space remained about 1.4–1.5 MiB and returned near baseline between passes.
  GC work grew roughly with declaration count (8,018 collections through the
  512 case). This shows high allocation cost, not a demonstrated accumulating
  leak or a bound on peak live space. The independent TCC task 100 remains
  running in parsing; its checkpoint/replay, large-heap and upstream prechecks
  passed. No retry of the synthetic diagnostic was launched.
- Task 100 failed after 9h36 overall, again immediately after `add32le`.
  Crucially, retained space was only 1,345,052 eight-byte units (~10.3 MiB)
  at the preceding function boundary. This does not look like a persistently
  full 512 MiB live heap; an individual allocation/compiler path needs isolation.
  The complete normalized AST survived: `/tmp/qfitzah-tcc-mes-atomic/tcc.E`
  (2,020,921 bytes), with `.complete` marker and a recorded `.sha256` file.
  The monitor was stopped; no source reparse was launched.
- Snapshot `bg_8g9v_mv1ifhbc_103` replays that checkpoint with a diagnostic wrapper
  around upstream `ast->info`, logging translation-unit child indices and nearby
  declarations. `add32le` is child 568; the next items are function prototypes.
  It has a 30-minute diagnostic deadline and writes only `tcc-debug.M1` if it
  reaches emission. This should localize the failing backend operation without
  spending another multi-hour frontend run. Task 103 failed after 7m18s at
  child 608: `static TokenSym *hash_ident[16384]`, nominally 65,536 bytes on
  i386. The diagnostic monitor was stopped.
- Task `bg_8g9v_mv1ird54_105` reduces this to a tiny actual C file with an integer
  typedef and the same pointer array, wrapping upstream `global->info` to log
  computed byte sizes before allocation. It has a five-minute deadline.
  Separately, the existing host successfully converted a native 65,536-byte
  NUL string to a 65,536-element list, so that basic operation alone is not
  sufficient to reproduce the failure. Task 105 passed in 45s, reporting the
  correct size of 65,536 bytes and emitting M1 for the isolated C program.
- The small reproducer's success makes fragmentation a concrete hypothesis:
  aggregate free space need not contain a 65,544-byte block (payload + header).
  Added private `%gc-largest-free-units`, collecting then measuring the largest
  swept block or unused bump tail. Extended its 64 KiB native diagnostic test.
  Task `bg_8g9v_mv1ixkge_106` rebuilds/tests this telemetry and replays the full
  checkpoint with per-global computed size, retained space and largest-block
  readings. It deliberately stops after `hash_ident` if successful; this is not
  a full TCC build. Task 106 confirmed fragmentation at `hash_ident`: computed
  size 65,536 bytes, 1,330,512 retained units (~10.2 MiB), but largest free block
  only 4,776 units (38,208 bytes). It failed after 8m19; watcher 107 was stopped.
- Implemented segregated nonmoving arenas: total blocks below 4 KiB use the
  small arena, other blocks the large arena. Each has independent bump/free
  lists; owners span both, sweeping never crosses the unused gap, and dead
  trailing runs return to bump space. Atomic/traced payload flags remain intact.
  `GcHeapBytes` is now per-arena capacity. The host selects 256 + 256 MiB,
  preserving the previous 512 MiB total object budget and metadata sizes.
  Ordinary rsc defaults to 128 MiB per arena; bounded host fixtures use 2 MiB
  per arena, rather than claiming a 2 MiB total bound.
- New fragmentation regression: at the SAME 128 KiB total object budget,
  the old single arena fails after small-object scattering, while two 64 KiB
  arenas pass large vector allocation, cross-arena/cyclic roots, byte buffers,
  and a larger allocation spanning reclaimed tail plus unused bump space.
  Existing native GC, byte-precision, telemetry and OOM tests also pass.
  Full immutable checks run as `bg_8g9v_mv1jixhe_108`.
- Task `bg_8g9v_mv1jls52_109` rebuilds Scheme stages, verifies native memory/
  control/ports and bounded/large hosts, rebuilds the M1 linker, tests upstream
  behavior/checkpoint replay and four C probes (including a 64 KiB pointer table),
  then resumes TCC backend/link/rebuild/probes from the preserved AST. New tool
  directories are `/tmp/qfitzah-segregated-stages`, `/tmp/qfitzah-host-segregated`
  and `/tmp/qfitzah-m1-segregated`; TCC output stays in its embedded-prefix
  directory `/tmp/qfitzah-tcc-mes-atomic`. `build-tcc-mes.sh --from-ast` requires
  the checkpoint/marker/prepared source and refuses existing M1 output. The
  default fresh end-to-end recipe remains unchanged. Watcher 110 checks every
  15 minutes. Launch is not evidence of successful TCC compilation.
- Tasks 108/109 failed before TCC: the first native rsc, emitted by sc1, still
  had fixed 256 MiB BSS. ELF inspection confirmed 268,435,456 reserved bytes;
  the new arena/metadata layout exceeds that mapping. sc1 now emits symbolic
  `RuntimeMemoryBytes`, defined by sc1-runtime as its existing fixed reservation
  and by rsc-runtime as `GcMemoryBytes`. This fixes the cross-runtime bootstrap
  boundary instead of changing sc1's own allocator. Watcher 110 was stopped.
  Fresh full checks are `bg_8g9v_mv1jsmbp_111`; snapshot continuation
  `bg_8g9v_mv1jt1cv_112` rebuilds into `/tmp/qfitzah-segregated-fixed-stages`,
  repeats all prechecks, then resumes the same TCC checkpoint. Watcher 113
  monitors every 15 minutes. Tasks 111/112 progressed past that bootstrap
  boundary and passed native memory/control/ports plus bounded host tests, then
  failed the large-host fixture's second 160 MiB allocation. Measurements show
  the previous single-arena host ALSO retained ~156 MiB after the fixture cleared
  its binding; it merely had room for another 160 MiB. That fixture never proved
  reclamation. It now tests one 160 MiB live set through collection, while native
  GC/fragmentation fixtures continue to prove reclamation and block reuse.
  The corrected capacity fixture passes directly on the segregated host.
  Watcher 113 was stopped. Current-source full checks are task 114; task 115
  reuses the validated `/tmp/qfitzah-segregated-fixed-stages` and repeats the
  corrected capacity/upstream/checkpoint/C checks before TCC continuation.
  Watcher 116 monitors it every 15 minutes. Task 114 passed all immutable
  checks in 3m02s, including both compiler lineages, the runtime-selected sc1
  reservation, segregated-arena regressions and corrected host capacity test.

### Performance target (user request): fresh end to end under four hours

- Acceptance now includes a measured fresh `build-tcc.sh` run under four hours,
  including compiler/host/linker construction, Nyacc regeneration, C frontend,
  libc/TCC compilation/linking, self-rebuild and final probes. Checkpoint replay
  and short benchmarks do NOT satisfy this target. Preserve the progressing
  task 115 rather than throw away its backend work; watcher 116 remains active.
- Added bounded real-upstream normalization probe `tests/probes/mescc-speed.scm`.
  Task 117: 128 declarations through four normalization passes took 113.991s
  wall / 112.426s user and 527 collections on the segregated baseline host.
- Implemented nonallocating native private `%env-find` for the existing host
  frame representation. Parent/fallback precedence, syntax/value slots, shared
  mutable cells and hygienic identity remain unchanged. No hash-table redesign.
  Native differential tests cover those properties and deep frames across GC.
  Task 118 passed stage builds, native GC/lookup tests, bounded/upstream hosts,
  checkpoint M1 equivalence and all four linked C probes. Normalization took
  85.833s wall / 84.586s user and 322 collections: 1.33x faster, ~39% fewer
  collections. Useful, but nowhere near proof of the four-hour goal.
- Direct let-frame compilation is under validation: create the same lexical
  frame without allocating a throwaway callable closure and dispatching it.
  Added initializer-scope, mutable-capture, restore and tail-recursion tests.
  Task 119 runs full immutable checks; task 121 builds/tests/benchmarks this
  candidate separately in `/tmp/qfitzah-direct-let-stages` and
  `/tmp/qfitzah-host-direct-let`.
- Task 120 instruments a copied host only, counting evaluator calls inside
  macro expansion, expansion count, identifier-strip visits and environment
  searches. Its source is `/tmp/qfitzah-profile-source`; it is diagnostic, not
  a shipped runtime or a performance comparison. Use results to target larger
  costs before another full source build.
- Task 119 passed full immutable checks (3m41s). Task 121 passed native GC,
  control, bounded/upstream hosts, trace/checkpoint equivalence and all four C
  probes with direct let frames. Normalization is now 67.102s / 309 collections
  (1.70x baseline), not enough by itself.
- Task 120 found 12,092,854 of 12,486,058 evaluator calls inside macro expansion
  (96.85%), for only 64 declarations; 50,979 expansions, 791,900 identifier-strip
  visits and 12,989,371 environment searches. Target this measured cost.
- Added `mes-host/analyze.scm`: analyze the core code produced by the unchanged
  Mes syntax-rules compiler into native execution closures. This is NOT an
  expansion cache: transformers still execute on every call with fresh hygiene
  callbacks and live global lookups. Unsupported code falls back as a whole to
  the reference evaluator; `QFITZAH_DISABLE_ANALYSIS=1` enables differential tests.
  Task 122 passed upstream fixtures, actual C probes, trace/checkpoint equality,
  all eight existing Nyacc artifact comparisons and their execution probes.
  Normalization: 25.447s / 105 collections, 4.48x the baseline, all eight loaded
  transformers analyzed. Standalone analyzed/reference syntax tests also pass
  (nested ellipses, vector/dotted patterns, literal scope, local captures,
  hygiene, effects and errors). Native core/reference tests pass, including
  unsupported-form fallback, import shadowing after analysis and continuations.
- Guarded primitive register-entry calls are under validation. They compare the
  operator captured before operand evaluation against a rooted immutable original
  primitive, skip temporary argument-list construction only at matching arity,
  and retain the original dynamic path for rebinding/shadowing. New tests cover
  those cases and operand order. A multiline shorthand macro mistake caused task
  123 to fail the source-macro test immediately; converted it to explicit Rule,
  then source-macro and analyzer-core checks passed. Full checks are task 124;
  task 125 builds/benchmarks the combined candidate and repeats upstream/C checks.
  Task 125 passed native memory/control, analyzer-core/reference tests, bounded
  and upstream hosts, macro differential fixtures, checkpoint replay, four linked
  C probes, and all Nyacc artifact/execution checks. Normalization is 20.627s /
  87 collections: 5.53x baseline and 83.5% fewer collections. Full immutable
  task 124 passed all checks in 4m43s, including both compiler lineages and the
  new primitive-dispatch/analyzer regressions, superseding task 123's corrected
  source-macro failure. The trace fixture now also
  compares C-to-M1 bytes with transformer analysis explicitly disabled.
- Fresh end-to-end task 126 (`bg_8g9v_mv1yblaf_126`) started at approximately
  2026-10-10 05:26 UTC into `/tmp/qfitzah-fast-e2e`. It invokes the complete
  recipe from the seed and pinned source directories, regenerating Nyacc and
  parsing TCC C source: no reused tables, AST checkpoint, libc or native stages.
  Timing covers the complete recipe; `/tmp/qfitzah-fast-e2e.timing` records exit
  and elapsed seconds. A successful recipe taking >=14,400 seconds is explicitly
  a target failure, but a late run is not killed and valid artifacts are retained.
  Watcher 127 monitors every 15 minutes. The four-hour target is still unproven.
- Task 115 finished MesCC's complete `infos->M1` emission, but failed linking
  after 499m23s: `_put_got_entry_16_break` had conflicting definitions. Its
  completed assembly and checksum are preserved as
  `/tmp/qfitzah-tcc-mes-atomic/tcc.unpatched.M1` and adjacent checksum files;
  obsolete watcher 116 was stopped. This is not a successful TCC executable.
  The pinned compiler drops AST comments in Mes/reproducible mode while using
  text length for labels, allowing an enclosing `if` and its ternary test to
  allocate the same label. A small unmodified-backend reproduction fails with
  `_choose_1_break` in `/tmp/qfitzah-mescc-fixes-proof.p7W5U8/old.err`.
  Inspection also found repeated string-pool labels and tentative/initialized
  global definitions at different addresses; relaxing the linker would hide
  incorrect control flow and initialization.
- `bootstrap/mescc-fixes.scm`, loaded by the restricted driver, repairs these
  cases at the Scheme compiler source level: zero-byte comments reserve label
  positions, named declarations retain definitions across tentative/extern
  redeclarations, and identical string keys are emitted once. The pinned tree
  stays untouched and conflicting M1 labels remain errors. Task 129 passed in
  3m05s: `mescc-labels.c`, trace/reference/replay equality, and all five linked
  C probes.
  Task 128's diagnostic used the wrong x86 macro input; task 129 corrects that
  harness error, without changing the reproduction or compiler repairs.
  Task 131 (`bg_8g9v_mv2308yu_131`) verifies the preserved hashes, archives the
  unpatched M1, then uses the optimized host and corrected immutable recipe to
  replay the old AST, link, rebuild and test TCC. Watcher 132 monitors it every
  15 minutes. This replay is component recovery, not fresh timing evidence.
- Watcher 130 confirmed fresh task 126's complete AST at 08:58:47 UTC. Its
  unpatched backend was stopped at 213m05s (because of the known correctness
  defect, not merely elapsed time), after hashing the checkpoint. Watcher 127
  was stopped too. Task 133 (`bg_8g9v_mv25zwty_133`) uses a new immutable corrected
  recipe with that run's own host, linker, regenerated Nyacc, libc and AST; it
  reruns the new label and trace checks, then compiles, links, rebuilds and tests
  TCC. Watcher 134 monitors every 15 minutes. Recovery timing is separate in
  `/tmp/qfitzah-fast-e2e.recovery.timing`; this is not a fresh recipe pass.
- The 15-minute evidence shows `c99-input->full-ast done` by 07:26:22 UTC,
  whereas normalization/checkpointing finished around 08:58:47: over 92 minutes
  remained after parsing. Collections rose from 4,936 to 21,587 before the AST
  save. The small normalization benchmark therefore understates the remaining
  real-input bottleneck. The fresh and earlier optimized host binaries compare
  identical. Corrected backend task 131 reached `default_outputfile` after
  81m38s; neither executable TCC nor the four-hour target is proven yet.
- Task 131 completed corrected TCC M1 emission after 101m16s, then failed
  linking against the old libc: both translation units emitted the function-
  pointer typedef `comparison_fn_t` as data. The corrected TCC M1 has no internal
  duplicate labels; this is the only shared label between it and libc. Its
  checksum is saved, and watcher 132 was stopped. No executable TCC is claimed.
- The new two-unit `tests/mescc-units.sh` regression uses a shared callback
  typedef, `sizeof`, real pointer storage and an indirect call. Tasks 135/137
  first exposed that suppressing typedef data alone is insufficient: upstream
  also fails to register the alias in `.types`. The driver now registers the
  function-pointer type and omits its false object definition; the writer also
  filters any residual typedef records. The fixture is included in the default
  C suite. Task 139 (`bg_8g9v_mv26w0mp_139`) gates a corrected libc build and relink
  of the preserved TCC M1 on these regressions, then attempts self-rebuild/tests;
  watcher 140 monitors it. No TCC frontend/backend repetition is needed for
  this relink. The unused typedef object remaining in the preserved TCC M1 does
  not collide with the corrected libc; a new full recipe omits it in both.
- Task 133's valid backend work continues; it still uses the old libc and is
  expected to encounter the same cross-unit collision after producing its M1.
  Task 141 (`bg_8g9v_mv26xut6_141`), monitored by 142, separately builds
  `/tmp/qfitzah-fast-e2e/libc-tcc-corrected` using that run's own host and Nyacc.
  After inspecting both terminal results, relink its preserved assembly with
  this libc rather than recompile TCC. Tasks 135/137 never reached libc builds;
  watcher 136 was stopped and 138 observed 137's failure. Their retries include
  the type-registration repair. Task 139 has now passed all five single-unit
  probes, the shared-typedef/indirect-call regression, and analyzed/reference
  trace/replay equality. Task 141 independently passed the shared-typedef
  regression with the fresh host and completed its corrected libc in 22m48s
  overall. Its saved M1 checksum verifies and `comparison_fn_t` is absent;
  watcher 142 was stopped. Task 133 is still generating TCC's backend, so this
  libc is ready for a later relink, not yet linked. Task 139 is still compiling
  its own corrected libc. Execution and self-rebuild remain pending.
- Task 139 successfully linked and executed `tcc-mes`, rebuilt TCC boot0..boot3
  and its libc in 3.084s, and verified boot2/boot3 plus runtime byte fixpoints.
  It then exited 4 in the final C probe, isolating signed 64-bit division. Mes's
  `lib/libtcc1.c` explicitly narrows operands to 32-bit `long`; bootstrap helpers
  are not an adequate final runtime. Watcher 140 was stopped. The original
  compiler/runtime artifacts are retained under
  `/tmp/qfitzah-tcc-mes-atomic/mes-runtime-checkpoint`.
- `build-tcc-libc.sh --bootstrap-runtime` now explicitly selects those limited
  helpers. After boot0..boot3 converge, `rebuild-tcc.sh` builds TCC's own i386
  `libtcc1.c`, `alloca86.S` and `alloca86-bt.S` with the bootstrapped TCC (including
  its assembler/archiver), then rebuilds full0..full2 and requires full1/full2
  and complete runtime fixpoints. This fixed wide division, exposing probe exit
  5: Mes `abtod` parses 1.25 as 3.5 by dividing its whole fractional part by 10.
- The TCC-built unified libc now substitutes the documented GNU-Mes-derived
  `bootstrap/mes-libc/abtod.c`: no 32-bit integral accumulator, digit-wise
  fractions, sign handling, bounded decimal/hex exponents and end pointers.
  It is intentionally a small converter, not a claim of fully correctly-rounded
  or locale-complete strtod; Inf/NaN spellings and extreme mantissa/exponent
  cancellation remain outside coverage. Original Mes sources remain untouched.
- Successful recovery evidence: immutable recipe
  `/tmp/qfitzah-numeric-runtime-source.R0C8zT` rebuilt all bootstrap/full rounds;
  `/tmp/qfitzah-tcc-mes-atomic/numeric-runtime-rebuild.log` records results.
  The recovered `/tmp/qfitzah-tcc-mes-atomic/tcc` passes `tests/tcc.sh`, now also
  including `tcc-numeric.c`: signed division boundaries/sign combinations,
  non-power-of-two wide unsigned division, variable shifts, float conversions,
  IEEE word oracles for decimal conversion/end pointers and variable-length
  stack arrays. Existing ABI, allocation, file I/O, inferred arrays, repeated
  output equality and invalid-C checks pass too. Independent commands verified
  full1/full2 equality, every `libc-fixpoint.sha256` object/archive (including
  alloca objects), and `tcc.sha256`. This is working TCC and self-rebuild through
  source-only recovery, NOT a fresh end-to-end or four-hour acceptance pass.
  Task 143 (`bg_8g9v_mv28hpro_143`) passed immutable full Nix checks and repeated
  recovered-TCC probes/hash verification in 4m27s; watcher 144 was stopped.
  This recovers the earlier build-operation incidents, not the timing target.
  The derived
  converter's GPLv3 license is copied verbatim into `bootstrap/mes-libc/COPYING`.
- Task 133 still uses its earlier immutable recipe. Once its valid assembly is
  complete, relink with task 141's corrected libc and use the CURRENT numeric
  runtime rebuild recipe, not the old Mes-only runtime recipe in its snapshot.
- Task 133 finished its independent TCC M1 in 101m18s (102m33s including
  prechecks), then hit the expected `comparison_fn_t` collision with its old
  libc. Its M1 and hash are preserved; watcher 134 was stopped. Task 145
  (`bg_8g9v_mv29orjb_145`) relinks with task 141's own-chain corrected libc,
  performs the current full-runtime rebuild/probes/fixpoints and records
  `toolchain.sha256`. Task 145 passed in 2m11s, including independent full-runtime
  TCC probes and fixpoints; watcher 146 was stopped. Recovery timing stays
  separate in `/tmp/qfitzah-fast-e2e.final-recovery.timing`, never a four-hour pass.
- Native normalization prototype: `build-mescc-normalizer.sh` uses the
  bootstrapped host to extract original pinned Mes definitions (retaining
  leading copyright/license notices), then compiles them through rsc into a
  stdin/stdout AST filter. No hand-rewritten normalization rules or host Scheme
  are used. Task 147 (`bg_8g9v_mv29smn1_147`) builds it and compares a bounded
  fixture covering comments, const qualifiers, attributes, inline specifiers,
  dotted pairs and the original rules' nonrecursive special cases against the
  unmodified interpreted passes. Subsequent failures, repairs and full-input
  validation are recorded below.
- Task 147 failed before compilation on unavailable `read-line`; the extractor
  now uses supported character primitives. Task 148 then built the executable
  in 5.647s but its first input crashed. Investigation found an actual rsc
  macro bug: `sr-match` treated `_` as wildcard even when explicitly listed as
  a literal. Mes's `ppat` therefore skipped pattern bindings, generating free
  references to `qual`, `h`, etc. The matcher now respects literal underscores;
  `rsc-macros.scm` tests `(17 42)` versus the old incorrect `(17 17)`. A native
  `core:reverse!` adapter also completes upstream `cons*`'s dependency boundary.
  Task 151 (`bg_8g9v_mv2a76m4_151`) verifies the old failure, both updated compiler
  lineages and the normalizer differential: it passed in 27s, recovering tasks
  147/148. Task 152 (`bg_8g9v_mv2a7c3v_152`) independently passed full immutable
  Nix checks in 4m31s.
- Opt-in `QFITZAH_MESCC_RAW_AST_OUTPUT` intercepts the source frontend before
  normalization/backend, saves a distinct `qfitzah-mescc-raw-ast-v1` checkpoint
  and exits. A bounded C smoke test verified completion, no M1 output and
  overwrite refusal. Ordinary compilation is unchanged. Task 149
  (`bg_8g9v_mv2a1dop_149`) passed in 24m11s, capturing the raw TCC AST with the
  exact fresh run's prepared source, include paths and flags into
  `/tmp/qfitzah-native-tcc-oracle/tcc.raw`. Watcher 150 was stopped. The preserved
  `/tmp/qfitzah-fast-e2e/tcc/tcc.E` supplies the original interpreted oracle.
- Optional pipeline integration now uses upstream's parsed options to select a
  single C source; its original argv/output name is preserved for backend replay.
  `.E` and multi-input compilations fall back to ordinary upstream compilation.
  Native normalization has separately named stderr/heap trace events, normalized
  checkpoint markers are written only on success, and failure artifacts remain.
  Task 153 (`bg_8g9v_mv2anp2b_153`) passed in 5m57s: exact C-to-M1 equality,
  fallback/checkpoint/EOF guards, all five linked C probes, shared-typedef units,
  and trace/reference/replay. Its 128-declaration differential took 19.640s
  interpreted versus 0.215s native, including input/output (~91x).
- Task 154 (`bg_8g9v_mv2axjx7_154`) verified both input hashes and normalized the
  complete raw TCC AST in **35.214s wall / 31.889s user**, including input/output.
  Heap events reported 1,004,177 retained eight-byte units before the passes and
  1,758,365 after; GC counts 126 -> 135. The result compared equal as Scheme data
  to the preserved interpreted AST; comparison took another 30.545s. Output and
  hash: `/tmp/qfitzah-native-tcc-oracle/tcc.native.E{,.sha256}`. This is full-input
  semantic and component-performance evidence, not end-to-end acceptance.
- `build-tcc.sh` now builds this helper from its own seed/rsc/host, runs its
  differential suite, enables it for subsequent MesCC compilation, and includes
  it in `toolchain.sha256`. The standalone driver remains opt-in.
- **Fresh acceptance task 155 (`bg_8g9v_mv2bbjwz_155`) started at approximately
  2026-10-10 11:30 UTC**, output `/tmp/qfitzah-native-e2e`. It uses an immutable
  source snapshot, the explicitly trusted seed (hash `abd1975d...aa`) and pinned
  source trees only: no reused stages, generated Nyacc, libc, AST or M1. The
  monotonic timer includes snapshot copying and the entire recipe; completion
  writes `/tmp/qfitzah-native-e2e.timing`. Exceeding 14,400s will NOT stop valid
  work, but will fail timing acceptance after completion. Watcher 156
  (`bg_8g9v_mv2bbpay_156`) checks every 15 minutes.
- Next: inspect the fresh complete result and timing, then finish the dependency,
  provenance, reproducibility and complexity audit. Recovered TCC execution and
  self-rebuild are verified; fresh-under-four-hours acceptance remains pending.
