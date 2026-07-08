# x86_64 MesCC — status

Built from the 1.7 KiB seed with no C and no Python, the `qmes-64` variant
(`bootstrap/qmes.scm` + `bootstrap/qmes-w64.scm`: 64-bit numbers as
`[TNUMBER|hi|lo]` in the existing 3-word cell, with a pure-Scheme w64 op layer
over the w32 primitives) runs GNU Mes's MesCC targeting x86_64.

## Proven (byte-identical to the M2-Planet amd64 reference `bin/mes-m2-64`)
- **w64 torture matrix** (`tests/mes-64/w64-ops.scm`): every w64 op × corner
  values × shift counts, byte-exact vs `bin/mes-m2-64`.
- **F1-64 — 20/20 byte-identical.** `mescc -S -m 64 --arch=x86_64` over all 20
  `mes_SOURCES` under `qmes64.elf` produces assembly byte-identical to the same
  MesCC run under `bin/mes-m2-64` (`tests/mescc-references/fixpoint-64/f1-64.sha256`).
- **F2-64 — linked ELF64 byte-identical.** Linking each path's 20 `.s` (crt1 +
  units + libc, mescc-tools amd64, base 0x1000000) yields a byte-identical
  runnable amd64 `mes` binary from both paths (sha256 `34c87cbc…`, 157302 bytes;
  the link is driven by the i386 `bin/mes-m2` because the amd64 `mes-m2-64`'s
  fixed exec-argv buffer overflows on the 20-file command). The binary runs
  natively (`(+ 40 2)` → 42).

So the x86_64 MesCC output of `qmes64` is **path-independent and byte-identical
to the M2-Planet reference all the way to the linked binary** — the substantive
x86_64 result.

## Not closed: F3-64 (self-recompilation)
Running the MesCC-linked amd64 `mes` binary to recompile `src/*.c` SIGSEGVs on
the full mescc workload (even at MES_ARENA=300M) — but the **reference-path
binary is byte-identical (`34c87cbc`) and crashes identically**, so this is a
property of GNU Mes 0.27.1's amd64 MesCC-built binary under load, NOT of the
qfitzah bootstrap or qmes64. The i386 fixpoint (`make fixpoint`) closes F1/F2/F3
fully; GNU Mes's amd64 MesCC self-hosting is less mature, and our bootstrap
reproduces the reference's amd64 behavior exactly (identical binary).
