# Native Mes AST normalization

`build-mescc-normalizer.sh SEED RSC HOST MES_SOURCE NEW_DIRECTORY` extracts
original definitions from the pinned Mes source with the source-built host,
then compiles them through rsc and the seed assembler. No host Scheme, C
compiler or assembler is used. Leading upstream copyright/license notices are
retained in `upstream.scm`; GNU Mes's GPLv3 text is also available in
`../mes-libc/COPYING`.

Extracted definitions:
- `ast-strip-comment`, `ast-strip-const`, `ast-strip-attributes`,
  `ast-strip-inline`, `qual-const?` from `module/mescc/preprocess.scm`;
- `pmatch`/`ppat`, `filter-map`, `list?`, and `cons*` from Mes's Scheme modules.

`primitives.scm` supplies the destructive `core:reverse!` boundary used by
`cons*`. The AST transformations themselves are not rewritten or fused. Their
special cases intentionally do not always recurse; differential tests retain
those semantics.

The executable reads one Scheme datum from stdin, applies the four passes in
upstream order, and writes one datum. Empty/trailing input is rejected. Optional
trace/heap events go only to stderr and identify `native-normalize`, not the
interpreted procedure that it replaces.

The complete builder builds and uses this helper from its own seed/rsc/host.
For standalone use, set `QFITZAH_MESCC_NORMALIZER` to this executable to opt
`mescc.sh` into a split source-frontend/native-normalization/source-backend pipeline. Upstream's parsed
options select a single C input; AST replay and other input shapes use ordinary
compilation unchanged. Original arguments and output names are retained. The
existing `-S` restriction and external-tool guards still apply.

The raw frontend's completion marker is `qfitzah-mescc-raw-ast-v1`, distinct
from the normalized `qfitzah-mescc-ast-v1` checkpoint. Neither is written before
the corresponding output closes successfully. Failed temporary work is retained
for diagnosis; successful temporary work is removed.

`tests/mescc-normalizer.sh` compares the native passes to unmodified interpreted
Mes, compares actual C-to-M1 output, and checks raw checkpoints, input guards and
multi-input fallback. `tests/mescc-trace.sh` also checks normalized checkpoint
replay. Full raw TCC normalization took 35.214s including input/output and produced
an AST equal to the preserved interpreted result (previously over 92 minutes
between parsing and checkpoint completion). The 128-declaration differential
measured 19.640s interpreted versus 0.215s native. These are component results:
a fresh complete build under four hours remains the acceptance requirement.
