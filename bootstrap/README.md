# Bootstrap

`qfitzah-stage1.qf1` is the first self-regeneration stage. It is a
hand-maintained, annotated Qfitzah source file that emits the executable bytes
of a built `qfitzah` binary.

The trusted seed is the hand-assembled `qfitzah.s` interpreter. Once that binary
exists, it can run:

```sh
qfitzah < bootstrap/qfitzah-stage1.qf1 > qfitzah-stage1
chmod +x qfitzah-stage1
```

The emitted file is byte-for-byte identical to the trusted seed executable. The
test suite compares the bytes directly, marks the generated file executable, and
reruns the normal language tests with it.

The file follows the stage0/hex0 style: ELF fields are listed by name, and the
`.text` section is emitted one i386 instruction per line with the disassembled
assembly in a comment. `B1` through `B16` emit raw byte fields, while the code
section uses instruction macros such as `MOV-EAX-IMM32`, `CALL-REL32`, and
`JE-REL8`.

This is intentionally a direct binary emission stage, not yet a symbolic
assembler or compiler. It establishes the bootstrap shape:

1. trust the original assembly once;
2. run Qfitzah source through that seed;
3. regenerate the interpreter binary;
4. compare the regenerated binary to the seed;
5. use the regenerated interpreter for the next checks.
