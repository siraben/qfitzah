

<
:main
	push___%ebp
	mov____%esp,%ebp
	sub____$i32,%esp %0x1054
	push___$i32 &_string_build/mescc/hello.s_0
	call32 %eputs
	add____$i8,%esp !0x4
	test___%eax,%eax
	mov____$i32,%eax %0x2a
	leave
	ret


:ELF_data


:HEX2_data

:_string_build/mescc/hello.s_0
"Hello, Mescc!
"
