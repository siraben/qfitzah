        ## Stage 0 collector: mark and sweep eight-byte cons cells in place.
        ## cell_state[i] describes arena + 8*i: 0 free, 1 live allocation,
        ## 2 marked during this collection. Free cells reuse their car word
        ## as a next pointer; they are never traversed as Scheme data.
        ##
        ## Called only by cons when its free list and bump space are empty.
        ## Keep all caller registers and flags. Scan the saved registers,
        ## stack, globals and atom buckets, but not the weak memo cache.
        ## Included last so gc_globals_end bounds the full range of `my` data.
        my gc_stack_top, 0
        my gc_free_head, 0
        my gc_work_top, gc_work
        .pushsection .data
gc_globals_end:
        .popsection

        .pushsection .bss
        .subsection 2
cell_state: .fill SEED_CELL_BYTES / 8
        .balign 4
gc_work: .fill SEED_CELL_BYTES / 2
gc_work_end:
        .popsection

proc gc_collect
        pushfl
        pushal
        movl $gc_work, gc_work_top-globals(%ebp)
        mov %esp, %esi
        mov gc_stack_top-globals(%ebp), %edi
        call gc_scan
        mov $globals, %esi
        mov $gc_globals_end, %edi
        call gc_scan
        mov $atoms, %esi
        mov $atoms_end, %edi
        call gc_scan
        call gc_drain
        call gc_sweep
        ## None of the old cache entries is valid once a cell can be reused.
        incl ev_gen-globals(%ebp)
        jnz 1f
        ## Counter wrap must not resurrect an ancient memo entry.
        mov $evcache, %edi
        xor %eax, %eax
        mov $(16 * (1 << evcache_bits) / 4), %ecx
        rep stosl
        incl ev_gen-globals(%ebp)
1:
        .ifdef SEED_GC_TRACE
        mov $__NR_write, %eax
        mov $2, %ebx
        mov $gc_trace_text, %ecx
        mov $1, %edx
        int $0x80
        .endif
        popal
        popfl
        ret

        ## Scan conservative machine words; gc_mark preserves both cursors.
proc gc_scan
        cmp %edi, %esi
        jae 1f
        lodsl
        call gc_mark
        jmp gc_scan
1:      ret

        ## EAX may be a raw/interior pointer or arbitrary machine word.
        ## Allocated-state metadata prevents tracing free-list links.
proc gc_mark
        cmp $arena, %eax
        jb 1f
        cmp allocation_pointer-globals(%ebp), %eax
        jae 1f
        sub $arena, %eax
        shr $3, %eax
        cmpb $1, cell_state(%eax)
        jne 1f
        movb $2, cell_state(%eax)
        lea arena(,%eax,8), %eax
        mov gc_work_top-globals(%ebp), %edx
        cmp $gc_work_end, %edx
        jae gc_out_of_memory
        mov %eax, (%edx)
        add $4, %edx
        mov %edx, gc_work_top-globals(%ebp)
1:      ret

        ## Pop one marked cell and scan its two words. Marking before
        ## enqueueing bounds the explicit work stack to one entry per cell.
proc gc_drain
        mov gc_work_top-globals(%ebp), %edx
        cmp $gc_work, %edx
        je 1f
        sub $4, %edx
        mov %edx, gc_work_top-globals(%ebp)
        mov (%edx), %esi
        lea 8(%esi), %edi
        call gc_scan
        jmp gc_drain
1:      ret

        ## Sweep only up to the bump pointer (the rest is unused space).
        ## Clear survivors' mark bits and rebuild the free list from scratch.
proc gc_sweep
        movl $0, gc_free_head-globals(%ebp)
        xor %ebx, %ebx
        mov $arena, %esi
1:      cmp allocation_pointer-globals(%ebp), %esi
        jae 4f
        cmpb $2, cell_state(%ebx)
        jne 2f
        movb $1, cell_state(%ebx)
        jmp 3f
2:      movb $0, cell_state(%ebx)
        mov gc_free_head-globals(%ebp), %eax
        mov %eax, (%esi)
        mov %esi, gc_free_head-globals(%ebp)
3:      inc %ebx
        add $8, %esi
        jmp 1b
4:      ret

proc gc_out_of_memory
        mov $__NR_write, %eax
        mov $2, %ebx
        mov $gc_error_text, %ecx
        mov $(gc_error_end-gc_error_text), %edx
        int $0x80
        mov $__NR_exit, %eax
        mov $1, %ebx
        int $0x80

        .pushsection .rodata
gc_error_text: .ascii "qfitzah: out of memory\n"
gc_error_end:
        .ifdef SEED_GC_TRACE
gc_trace_text: .ascii "G"
        .endif
        .popsection
