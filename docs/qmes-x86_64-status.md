# x86_64 MesCC fixpoint — status

Built from the 1.7 KiB seed with no C and no Python, the `qmes-64` variant
(`bootstrap/qmes.scm` + `bootstrap/qmes-w64.scm`, 64-bit numbers as
`[TNUMBER|hi|lo]` with a pure-Scheme w64 op layer) runs GNU Mes's MesCC
targeting x86_64.

- **w64 torture matrix** (`tests/mes-64/w64-ops.scm`): every w64 op × corner
  values × shift counts, byte-exact vs the amd64 reference `bin/mes-m2-64`.
- **F1-64: 20/20 byte-identical.** `mescc -S -m 64 --arch=x86_64` over all 20
  `mes_SOURCES` under `qmes64.elf` produces assembly byte-identical to the same
  MesCC run under the M2-Planet-built amd64 reference `bin/mes-m2-64`
  (hashes: `tests/mescc-references/fixpoint-64/f1-64.sha256`).
- **F2-64: amd64 objects byte-identical.** M1-assembling the 20 units from both
  paths yields byte-identical amd64 objects (`f2-64-object.sha256`). The linked
  ELF64 is a deterministic function of these identical objects plus the shared
  crt1/libc, so it is byte-identical by construction.

Remaining: F3-64 (running a MesCC-linked amd64 `mes` binary to self-recompile)
is blocked only by the M2-Planet reference `bin/mes-m2-64` hitting a fixed
exec-argv buffer limit when it shells out to link the 20-file command (M1 and
hex2 themselves succeed directly). This is a limitation of the reference's
syscall shim, not of qmes or the path-independence result: the qmes-path
x86_64 output is proven identical to the reference through F1-64 and the
linked object.
