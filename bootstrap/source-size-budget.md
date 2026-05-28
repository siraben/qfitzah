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
- `stage4-is-bytes-content-linear-direct.qf1`
  - content-based `IsBytes`
  - uses `qfc4-byte-output.qf1` and `qfasm-byte-output-ext.qf1`
  - keeps qfc4-local rules out of the fixture source
  - emits a byte-identical ELF and static `(Bytes 41)` as byte `41`
- `qfasm2-exit42-n221.qf1`
  - uses `qfasm-n221-ext.qf1`
  - assembles a 221-byte code segment, one byte past qfasm2's common `N220`
    file-size range
  - emits a runnable ELF that exits with status `42`

These larger combinations have failed in previous attempts and remain unmerged
until the common source is smaller or the combination is re-tested:

- general `EmitBytes` plus content-based `IsBytes`, including a retry with the
  direct byte-output compiler slice
- putting the content-comparison instructions into the common qfasm2/qfasm3/qfc4
  stages instead of keeping them local to a focused fixture

## Next Engineering Step

Before merging content-based `IsBytes` into the general compiled `EmitBytes`
fixture, reduce the always-loaded source:

- continue splitting optional qfasm2/qfasm3/qfc4 extensions into per-fixture
  files; the focused content-output path now has a checked split
- continue replacing explicit finite layout tables with generated arithmetic or
  smaller range-specific local tables
- extend the code-size range beyond the checked `N221` proof to real label,
  branch, and data addresses without overflowing the seed's atom/rule budget

Only after that should the byte-output milestone try to combine:

```text
content-based is_bytes + arbitrary cons-tail traversal + nested Bytes flattening
```
