# Source Size Budget

The current seed runtime can compile the staged runtime slices only while the
concatenated qfasm2 + qfasm3 + qfc4 + fixture source stays below a practical
source-size limit. This is a seed-runtime limit, not a target-machine-code
limit: adding rules to the common stages increases the input that the seed must
intern and rewrite before it can emit an ELF.

## Observed Boundary

These checked fixtures fit:

- `stage4-emit-bytes-general.qf1`
  - one compiled `EmitBytes` routine
  - cons-tail traversal
  - nested `(Bytes ...)` flattening
  - pointer-identity `IsBytes`
- `stage4-is-bytes-content.qf1`
  - content-based `IsBytes`
  - positive path only
  - local comparison rules
- `stage4-is-bytes-content-reject.qf1`
  - content-based `IsBytes`
  - negative final-character path
  - local comparison rules
- `stage4-is-bytes-content-output.qf1`
  - content-based `IsBytes`
  - gates a real byte-output path
  - emits static `(Bytes 41)` as byte `41`
- `stage4-is-bytes-content-linear.qf1`
  - content-based `IsBytes`
  - gates the same byte-output path
  - uses fixture-local scoped labels and fail-fast `jnz` branches
  - emits static `(Bytes 41)` as byte `41`

These larger combinations have failed in previous attempts and remain unmerged
until the common source is smaller or the combination is re-tested:

- general `EmitBytes` plus content-based `IsBytes`
- putting the content-comparison instructions into the common qfasm2/qfasm3/qfc4
  stages instead of keeping them local to a focused fixture

## Next Engineering Step

Before merging content-based `IsBytes` into the general compiled `EmitBytes`
fixture, reduce the always-loaded source:

- split optional qfasm2/qfasm3/qfc4 extensions into per-fixture files
- continue replacing explicit finite layout tables with generated arithmetic or
  smaller range-specific local tables
- move the proven local fail-fast branch primitive into a smaller optional
  extension layer only when a larger fixture needs it

Only after that should the byte-output milestone try to combine:

```text
content-based is_bytes + arbitrary cons-tail traversal + nested Bytes flattening
```
