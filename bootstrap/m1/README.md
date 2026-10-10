# Source-built i386 M1/hex2 linker

Build with `bash bootstrap/build-m1.sh SEED RSC_COMPILER NEW_DIRECTORY`.
The resulting `m1-link` is native rsc code, assembled by qfitzah. It does not
invoke a host assembler, linker, C compiler or Scheme interpreter.

```
m1-link --architecture x86 --little-endian --base-address 0x1000000 \
  -f x86.M1 -f elf32-header.hex2 -f program.M1 -f footer.hex2 -o program
chmod +x program
```

This is a **combined assembler/linker**, not a drop-in replacement for M1's
hexadecimal intermediate-output mode. MesCC must emit M1 source (`-S`); shell
orchestration then supplies its source objects and ELF header/footer together.
There is no requirement to trust preassembled `.o` or `.a` files.

- `lex.scm`: raw quoted strings, comments, source definitions and bucketed
  string-keyed tables. Macro definitions are collected before expansion.
- `layout.scm`: macro expansion with cycle rejection, numeric immediates,
  hexadecimal bytes, labels and four-byte alignment.
- `link.scm`: resolve absolute (`&`, `$`) and PC-relative (`%`, `@`, `!`)
  references, including `target>base` differences. Numeric immediates retain
  their low bits. Relative label references must fit their signed field;
  absolute references must fit their unsigned field.
- `main.scm`: explicit input/output paths and target/base options.

Double-quoted M1 strings are raw bytes followed by NUL; backslashes are literal.
Single-quoted strings contain hexadecimal bytes. The linker accepts coincident
label declarations (used by upstream headers) but rejects conflicting labels,
undefined references, malformed bytes, macro cycles and overflowing relocations.
All bytes and relocations are validated before opening an output file. Output
file permissions are an orchestration concern, not an implicit tool action.

Only the i386 little-endian subset is implemented. ARM/RISC-V relocations,
64-bit address fields and blood-elf debug-symbol generation are not supported.
Validation is in `tests/m1-link.sh SEED RSC_COMPILER [MES_SOURCE]`; the optional
source root exercises pinned Mes instruction definitions and ELF examples.
`tests/mescc-backend.sh HOST M1_LINK MES_SOURCE` also executes upstream MesCC's
instruction selection and M1 writer on hand-constructed IR, links global data
using Mes's full ELF header/footer, and verifies an exit status of 42. This is
not a C frontend test. Separately, `tests/mescc-c.sh` now passes real C frontend
compilation and ELF execution for globals, preprocessing, calls, structures,
arrays and control flow. Full libc/TCC linking remains pending.
