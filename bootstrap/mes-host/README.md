# Source-built Mes compatibility host (in progress)

`../build-mes-host.sh SEED RSC_COMPILER NEW_DIRECTORY` compiles the runtime
libraries and these files using rsc, then assembles the result using the seed.
Neither Guile nor a host C compiler is invoked. The assembly driver allows a
64 MiB traversal stack (`QFITZAH_ASSEMBLY_STACK_KIB` overrides this); this does
not change generated programs' stack limits. The resulting `mes-host` reads
stdin or loads Scheme source files. Integration milestones include Mes's syntax
compiler, all eight regenerated Nyacc parser artifacts, and actual MesCC C
compilation through source-built M1/ELF linking. C and Mes crt1/libc-mini probes
pass; full libc has compiled to M1, but **full libc linking and TCC remain
unverified**. The single-arena attempts failed from fragmentation at TCC's
64 KiB pointer table despite only ~10 MiB retained. The current allocator
separates large blocks from small-object churn; full TCC validation is pending.

```
mes-host --mes /path/to/mes-0.27.1 -L /path/to/nyacc-1.00.2/module program.scm
mes-host --mes /path/to/mes-0.27.1 -e main program.scm -- argument ...
bash tests/mes-upstream.sh /path/to/mes-host /path/to/mes-0.27.1
```

Performance work targets a fresh complete bootstrap under four hours; this is
not yet established. The host still interprets MesCC, but uses native frame
lookup and analyzes the core emitted by Mes's unchanged `syntax-rules` compiler
into execution closures. It does not cache macro expansions: each invocation
retains fresh hygiene callbacks and live global binding lookup. Unsupported
transformer code uses the reference evaluator. Set
`QFITZAH_DISABLE_ANALYSIS=1` for differential testing; see
`tests/mes-host-analyze{,-core}.sh` and `tests/probes/mescc-speed.scm`.

The default host profile in `heap.qf1` uses two 256 MiB arenas (512 MiB total),
a 256 MiB owner map, and a 128 MiB mark queue. Blocks below 4 KiB and larger
blocks have separate arenas/free lists. `GcMemoryBytes` in current rsc output reserves
sufficient ELF BSS for these and the I/O buffers. Rebuild rsc before building
this host: older compilers hard-code a 256 MiB mapping and are rejected by the
host builder. An optional fourth builder argument selects assembly overrides;
semantic fixtures use 2 MiB per arena. `tests/mes-host-large-heap.sh` checks
160 MiB of live buffers and collection, and safe exhaustion with 128 MiB per
arena. `tests/runtime-memory.sh` covers fragmentation and cross-arena roots.
Segregation preserves the previous host's total object-space budget; it is not
proof of TCC completion.

Use the pinned, verified archives described in `../upstream/README.md`. Module
search uses only explicit paths; there is no system Guile search or `.go` cache.
Unknown module options and missing bindings fail rather than silently ignoring
imports. The `(guile)` module is a snapshot of this source-built core, needed by
Mes's SRFI adapters to retrieve their original procedures. `(mes display)` is an
explicit four-procedure bridge to our source-built port writers: Mes's original
printer inspects its own VM cell layout and cannot be applied to rsc objects.
Its private raw-cell inspection helpers are not emulated. Mes's `/mes/module`
adapters take precedence over `/module` Guile adapters; `mes?` and `guile?`
identify that dialect explicitly.

## Implementation boundaries

- `environment.scm`, `evaluate.scm`: lexical mutable cells, native closures for
  interpreted procedures, evaluation and loading. Thus native continuations,
  GC, ports, exact integers and `apply` also handle interpreted procedures.
- `syntax.scm`, `derived.scm`: small core/derived-form handlers, optional and
  keyword parameters, promises, lexical environment access and `with-fluids`.
  Fluid value expressions are evaluated before binding, with reverse-order
  restoration across normal returns, exceptions and continuation transfers.
- `identifiers.scm`: explicit-renaming identifiers retain definition-site
  environments. Mes's **unmodified** `mes/module/mes/syntax.scm` supplies the
  actual syntax-rules compiler. Its generated transformer code executes in the
  compiler's private environment; source templates receive real renaming and
  binding-aware comparison callbacks. Quotation removes identifier wrappers.
- `modules.scm`: separate module environments, shared import cells, selection,
  renaming, prefixes and forward export cells for circular imports. `define`
  shadows imported bindings; `set!` writes through aliases. Core parents do not
  inherit interaction-environment redefinitions.
- Mes has separate macro and value namespaces. Procedural macros retain their
  definition environment as a fallback for private helpers while preserving
  use-site precedence and definitions. They are not hygienic; syntax-rules uses
  the explicit-renaming protocol instead.
- `records.scm`: typed vector records, constructors, accessors and reflection,
  including the field-name query used by Mes's immutable-record macros.
- `primitives.scm`, `library.scm`, `lists.scm`, `strings.scm`, `charsets.scm`, `format.scm`:
  explicitly registered source-built core facilities. Mes's SRFI, optargs,
  pmatch and pretty-print implementations load from their upstream source.
- `main.scm`: explicit source paths, script entry/arguments, and interpreter-local
  environment overrides. No subprocess execution or OS environment mutation is
  currently implemented.

`--mes` enables source dialect details found in the pinned implementation:
`(. datum)` reads as `datum`, hex string escapes may end at a non-hex character
(`src/reader.c`), and `if` ignores operands after its first alternative
(`src/eval-apply.c`). Nyacc and Mes's SRFI-1 use these spellings. The reader also
accepts legacy control-character names. Default reader/evaluator tests retain
strict dotted-list, hex-terminator and if-arity checks. Guile procedure-property
annotations are deliberately discarded, matching Mes's `guile.mes` adapter.
`/` uses Mes integer division (zero arguments yield 1; one yields itself).
`port-line` and `port-column` currently return zero, explicitly matching
`mes/boot-03.scm`; exact source-coordinate reporting is not implemented.
In Mes mode, unreading EOF is a no-op.

`../prepare-nyacc.sh SOURCE NEW_DIRECTORY` makes a working copy with all eight
distributed C99/CPP parser files removed and the documented one-line CPP module
import adaptation applied (`../upstream/README.md`). Run the pinned generation scripts in
that directory using `mes-host --mes MES_ROOT -L module gen-cpp-files.scm`, then
`gen-c99-files.scm` and `gen-c99cx-files.scm`. All eight outputs now match the
upstream read datums; all four tables are also byte-identical. The complete
fresh-directory recipe is `../regenerate-nyacc.sh`; `tests/nyacc-generated.sh`
validates the artifacts and executes CPP, full C, C99cx and pretty-printer cases.
`tests/nyacc-cpp.sh HOST MES_ROOT NYACC_WORK`
checks actual expression parsing, precedence, signed division, wide integers,
short-circuiting, defined/undefined macros and function-like macro expansion.

This is a tested bootstrap compatibility surface, not a claim of full Guile or
Scheme conformance. `../mescc.sh HOST MES_SOURCE GENERATED_NYACC -S ...`
runs the pinned frontend without permitting external compiler/assembler/linker
fallbacks. `tests/mescc-c.sh` verifies real C-to-ELF programs, separately from
the IR-only backend test. Set `QFITZAH_MESCC_TRACE=1` to report parser/compiler/
M1 phase boundaries, function compilation and GC counts to stderr; TCC's first
build enables it by default. Additionally set `QFITZAH_MESCC_HEAP_TRACE=1` to
collect and report retained eight-byte units at each event. This diagnostic
includes block headers/padding and may conservatively retain dead data; it is
not precise language-level liveness. With tracing enabled,
`QFITZAH_MESCC_AST_OUTPUT=NEW_PATH` saves the completed frontend AST and then
writes `NEW_PATH.complete`; existing destinations are rejected. The first TCC
build enables this checkpoint so backend failures need not discard the parse.
`tests/mescc-trace.sh` checks unchanged M1 output, including replay through the
upstream `.E` backend. These checkpoints are generated source data, not archive
parser artifacts or a host-compiler shortcut.
Full Mes libc linking, TCC and self-rebuild remain tracked in `BOOTSTRAP-PLAN.md`.
