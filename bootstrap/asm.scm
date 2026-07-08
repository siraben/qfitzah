; asm.scm -- a native i386 assembler in the rsc dialect.
;
; Reads a qfasm program  (Assemble (Program entry bss code))  from stdin (the
; exact text rsc emits) and writes to stdout an ELF that is BYTE-IDENTICAL to
; what  [seed + qfasm.qf1 (+ rsc-runtime.qf1)]  produces.  This escapes the
; seed's rewrite-arena ceiling: assembly is O(program) memory with native
; arithmetic and a hash symbol table, two passes over the input.
;
; The instruction encoding is a direct transliteration of
; tools/generate_qfasm.py; the ELF header is its (ElfHeader ...) rule; the two
; extra directives DObj / MovRIObj come from tools/generate_rsc_runtime.py.
;
; Runtime splice: rsc output ends its code chain with (RuntimeCode (RuntimeData
; End)); the seed expands those (rsc-runtime.qf1 macros) into the fixed runtime
; code/data instruction chains.  asm.elf recognises the two forms and splices
; in the SAME instructions, read at startup from a flat runtime file (argv[1],
; produced by `python3 tools/generate_rsc_runtime.py --flat`).  A bare program
; (a qfasm fixture) needs no runtime file.
;
; MEMORY.  rsc has no GC: every Scheme call conses an env frame / arglist, and
; every string/vector has its header pair in the cell arena.  Reading a big
; program thus conses hundreds of MB of garbage that only host-heap-reset! can
; reclaim -- but a reset also frees any object (incl. string/vector headers)
; allocated after the mark.  So ALL state that must persist lives in buffers /
; vectors PRE-ALLOCATED before the reset floor and mutated in place:
;   * the whole input text is slurped into a pre-allocated byte buffer (P), the
;     runtime text into another (R);
;   * the two passes RE-PARSE from those buffers, reclaiming per-instruction
;     transient with host-heap-reset! every few dozen instructions (the walk is
;     niladic, all cursor/counter state in globals -> nothing pinned above the
;     floor);
;   * the symbol table is a pre-allocated open-addressing hash whose key bytes
;     live in a pre-allocated byte buffer;
;   * the output ELF is built in a pre-allocated byte buffer.
; Code offsets, sizes and label addresses are fixnums (< 2^30); only
; VBase-relative addresses and immediates use w32.  Result: O(1) live cell
; arena, so arbitrarily large programs assemble.
;
; Build:
;   cat bootstrap/rsc-prelude.scm bootstrap/asm.scm | rsc.elf > asm.qfasm
;   cat bootstrap/qfasm.qf1 bootstrap/rsc-runtime.qf1 asm.qfasm | seed > asm.elf
; Run:
;   cat PROG.qfasm | asm.elf RUNTIME_FLAT > PROG.elf      (runtime programs)
;   cat PROG.qfasm | asm.elf              > PROG.elf      (bare programs)

; ===========================================================================
; w32 constants for VBase-relative address arithmetic.
; ===========================================================================
(define w32-1 #f) (define w32-2 #f) (define w32-88 #f)
(define w32-255 #f) (define w32-vbase #f)
(define (vaddr off) (w32-add w32-vbase (w32-from-fixnum off)))
(define (asm-error m) (error m))

; ===========================================================================
; Input cursor over a pre-allocated byte buffer.  -1 signals end.  P is the
; program text, R the runtime text; the cursor points at one of them.
; ===========================================================================
(define cbuf #f) (define cpos 0) (define clen 0)
(define (pk) (if (>= cpos clen) -1 (char->integer (string-ref cbuf cpos))))
(define (nx) (let ((c (pk))) (set! cpos (+ cpos 1)) c))
(define (ws? c) (or (= c 32) (= c 9) (= c 10) (= c 13)))
(define (delim? c) (or (< c 0) (ws? c) (= c 40) (= c 41) (= c 59)))
(define (skip-comment)
  (let ((c (pk))) (cond ((< c 0) 'done) ((= c 10) (nx) 'done) (else (nx) (skip-comment)))))
(define (skip-ws)
  (let ((c (pk)))
    (cond ((< c 0) 'done)
          ((ws? c) (nx) (skip-ws))
          ((= c 59) (skip-comment) (skip-ws))
          (else 'done))))

; ===========================================================================
; Vocabulary: fixed tokens (mnemonics, registers, keywords) pre-interned once.
; A vocab token reads as its interned symbol (stable eq?, usable in case); any
; other token (label piece, hex/number operand) reads as a fresh byte-arena
; string.  Both are only ever used transiently, within one instruction.
; ===========================================================================
(define VSZ 1024)
(define vkeys (make-vector VSZ #f))
(define vvals (make-vector VSZ #f))
(define g-tok (make-string 512))
(define (str-hash s) (sh-loop s 0 (string-length s) 0))
(define (sh-loop s i n acc)
  (if (= i n) acc
      (sh-loop s (+ i 1) n (remainder (+ (* acc 31) (char->integer (string-ref s i))) 1000003))))
(define (slice-hash n) (slh-loop 0 n 0))
(define (slh-loop i n acc)
  (if (= i n) acc
      (slh-loop (+ i 1) n (remainder (+ (* acc 31) (char->integer (string-ref g-tok i))) 1000003))))
(define (slice=? k n)
  (and (= (string-length k) n) (sl-loop k 0 n)))
(define (sl-loop k i n)
  (if (= i n) #t (if (char=? (string-ref k i) (string-ref g-tok i)) (sl-loop k (+ i 1) n) #f)))
(define (vocab-add! name)
  (let ((sym (string->symbol name)))
    (let loop ((i (remainder (str-hash name) VSZ)))
      (if (eq? (vector-ref vkeys i) #f)
          (begin (vector-set! vkeys i name) (vector-set! vvals i sym))
          (loop (remainder (+ i 1) VSZ))))))
(define (vocab-lookup n)
  (let loop ((i (remainder (slice-hash n) VSZ)))
    (let ((k (vector-ref vkeys i)))
      (cond ((eq? k #f) #f)
            ((slice=? k n) (vector-ref vvals i))
            (else (loop (remainder (+ i 1) VSZ)))))))
(define (tok->string n)
  (let ((s (make-string n))) (copy-tok s 0 n) s))
(define (copy-tok s i n)
  (if (< i n) (begin (string-set! s i (string-ref g-tok i)) (copy-tok s (+ i 1) n)) s))
(define (rsym-fill i)
  (let ((c (pk)))
    (if (delim? c) i (begin (string-set! g-tok i (integer->char c)) (nx) (rsym-fill (+ i 1))))))
(define (read-atom)
  (skip-ws)
  (let ((n (rsym-fill 0)))
    (let ((v (vocab-lookup n))) (if v v (tok->string n)))))
; A datum is a transient vector (a list) or an atom (symbol/string).
(define (read-datum)
  (skip-ws)
  (let ((c (pk)))
    (cond ((< c 0) (asm-error "asm: eof in datum"))
          ((= c 40) (nx) (list->vector (reverse (read-elems '()))))
          (else (read-atom)))))
(define (read-elems acc)
  (skip-ws)
  (let ((c (pk)))
    (cond ((< c 0) (asm-error "asm: eof in list"))
          ((= c 41) (nx) acc)
          (else (read-elems (cons (read-datum) acc))))))
(define (expect-lparen) (skip-ws) (if (= (pk) 40) (nx) (asm-error "asm: expected (")))
(define (expect-sym s) (if (eq? (read-atom) s) #t (asm-error "asm: unexpected token")))

; ===========================================================================
; Slurp: fill pre-allocated buffers P (stdin) and R (runtime file).  Both are
; allocated before the floor, so their headers survive resets; slurping only
; mutates their bytes.
; ===========================================================================
(define P #f) (define plen 0)
(define R #f) (define rlen 0) (define rd-start -1)
(define P-CAP 16777216)                    ; 16 MiB program text (~700k instructions)
(define R-CAP 524288)
(define g-si 0)
(define (slurp-stdin!)
  (set! g-si 0)
  (slurp-loop))
(define (slurp-loop)
  (if (= (remainder g-si 65536) 0) (host-heap-reset! read-floor))
  (if (>= g-si P-CAP) (asm-error "asm: program exceeds P-CAP; raise it"))
  (let ((c (peek-char)))
    (if (eof-object? c)
        (set! plen g-si)
        (begin (read-char) (string-set! P g-si c) (set! g-si (+ g-si 1)) (slurp-loop)))))
(define (slurp-runtime!)
  (let ((path (runtime-path)))
    (if path
        (let ((fd (sys-open path 0 0)))
          (if (< fd 0) (asm-error "asm: cannot open runtime file")
              (begin (set! rlen (read-fd-all fd 0)) (sys-close fd)))))))
(define (read-fd-all fd off)               ; read into R[off..], return total len
  (if (>= off R-CAP) off
      (let ((n (sys-read-at fd off)))
        (if (<= n 0) off (read-fd-all fd (+ off n))))))
; sys-read into R at a given offset: read into a small chunk then copy in.
(define chunk #f) (define CHUNK 65536)
(define (sys-read-at fd off)
  (let ((n (sys-read fd chunk)))
    (if (> n 0) (copy-into-R chunk 0 n off))
    n))
(define (copy-into-R src i n off)
  (if (< i n)
      (begin (string-set! R (+ off i) (string-ref src i)) (copy-into-R src (+ i 1) n off))
      'done))
(define (runtime-path)
  (let ((a (command-line))) (if (and (pair? a) (pair? (cdr a))) (cadr a) #f)))
(define (has-runtime?) (if (runtime-path) #t #f))

; ===========================================================================
; Numbers and bytes.
; ===========================================================================
(define (hexdigit c)
  (cond ((and (>= c 48) (<= c 57)) (- c 48))
        ((and (>= c 65) (<= c 70)) (- c 55))
        ((and (>= c 97) (<= c 102)) (- c 87))
        (else 0)))
(define (hexval-str str) (hx-loop str 0 0))
(define (hx-loop str i acc)
  (if (= i (string-length str)) acc
      (hx-loop str (+ i 1) (+ (* acc 16) (hexdigit (char->integer (string-ref str i)))))))
(define (hexval-atom a) (hexval-str (if (symbol? a) (symbol->string a) a)))
(define (bv s) (hexval-atom s))
(define (num-value form)
  (let ((h (vector-ref form 0)))
    (cond ((eq? h 'Small) (w32-from-fixnum (hexval-atom (vector-ref form 1))))
          ((eq? h 'X8) (x8v form 1 (w32-from-fixnum 0)))
          (else (asm-error "asm: bad number form")))))
(define (x8v form i acc)
  (if (= i (vector-length form)) acc
      (x8v form (+ i 1) (w32-or (w32-shl acc 4) (w32-from-fixnum (hexval-atom (vector-ref form i)))))))
(define (reg-num s)
  (cond ((eq? s 'EAX) 0) ((eq? s 'ECX) 1) ((eq? s 'EDX) 2) ((eq? s 'EBX) 3)
        ((eq? s 'ESP) 4) ((eq? s 'EBP) 5) ((eq? s 'ESI) 6) ((eq? s 'EDI) 7)
        (else (asm-error "asm: bad register"))))

; ===========================================================================
; Symbol table: a pre-allocated open-addressing hash.  A label term is
; serialized to canonical bytes in a scratch buffer; the key bytes of bound
; labels are copied into a pre-allocated key buffer.  Everything here is
; mutation of pre-allocated storage -> survives resets.
; ===========================================================================
(define TSZ 262144) (define TMASK 262143)
(define t-koff #f) (define t-klen #f) (define t-val #f)
(define KEYBUF-CAP 8388608)                ; 8 MiB of key bytes
(define keybuf #f) (define keypos 0)
(define scratch (make-string 65536)) (define spos 0)
(define (sc-byte! b) (string-set! scratch spos (integer->char b)) (set! spos (+ spos 1)))
(define (sc-str! s) (scs-loop s 0 (string-length s)))
(define (scs-loop s i n) (if (< i n) (begin (sc-byte! (char->integer (string-ref s i))) (scs-loop s (+ i 1) n)) 'x))
(define (serialize! t)                     ; write canonical form of t into scratch
  (cond ((vector? t) (sc-byte! 40) (ser-vec! t 0) (sc-byte! 41))
        ((symbol? t) (sc-byte! 32) (sc-str! (symbol->string t)))
        ((string? t) (sc-byte! 32) (sc-str! t))
        (else (sc-byte! 63))))
(define (ser-vec! t i)
  (if (< i (vector-length t)) (begin (serialize! (vector-ref t i)) (ser-vec! t (+ i 1))) 'x))
(define (key-of t) (set! spos 0) (serialize! t) spos)   ; -> length; bytes in scratch
(define (scratch-hash n) (sch-loop 0 n 0))
(define (sch-loop i n acc)
  (if (= i n) acc
      (sch-loop (+ i 1) n (remainder (+ (* acc 31) (char->integer (string-ref scratch i))) 1000003))))
(define (kb=scratch? off len)
  (kbs-loop off 0 len))
(define (kbs-loop off i len)
  (if (= i len) #t
      (if (char=? (string-ref keybuf (+ off i)) (string-ref scratch i))
          (kbs-loop off (+ i 1) len) #f)))
; The seed binds labels newest-first and Lookup returns the first (newest)
; match, i.e. the LAST binding wins.  A few names (the P1-prim GV cells) are
; bound both in the user data section and in the runtime data; to match the
; seed we OVERWRITE an existing key rather than shadowing it.
(define (st-put! term val)
  (let ((len (key-of term)))
    (let loop ((i (remainder (scratch-hash len) TSZ)))
      (let ((off (vector-ref t-koff i)))
        (cond
          ((< off 0)
           (kb-copy! keypos 0 len)
           (vector-set! t-koff i keypos) (vector-set! t-klen i len) (vector-set! t-val i val)
           (set! keypos (+ keypos len)))
          ((and (= (vector-ref t-klen i) len) (kb=scratch? off len))
           (vector-set! t-val i val))                 ; overwrite: last binding wins
          (else (loop (remainder (+ i 1) TSZ))))))))
(define (kb-copy! off i len)
  (if (< i len) (begin (string-set! keybuf (+ off i) (string-ref scratch i)) (kb-copy! off (+ i 1) len)) 'x))
(define (st-get term)
  (let ((len (key-of term)))
    (let loop ((i (remainder (scratch-hash len) TSZ)))
      (let ((off (vector-ref t-koff i)))
        (cond ((< off 0) (error "asm: undefined label"))
              ((and (= (vector-ref t-klen i) len) (kb=scratch? off len)) (vector-ref t-val i))
              (else (loop (remainder (+ i 1) TSZ))))))))
(define (hget term) (st-get term))

; ===========================================================================
; Output buffer (pre-sized after pass1: 0x58 header + codesize).
; ===========================================================================
(define g-out #f)
(define g-out-pos 0)
(define (emit-byte b)
  (string-set! g-out g-out-pos (integer->char b))
  (set! g-out-pos (+ g-out-pos 1)))
(define (eb b) (emit-byte b))
(define (emit-bytes lst) (for-each emit-byte lst))
(define (emit-zeros n) (if (> n 0) (begin (emit-byte 0) (emit-zeros (- n 1))) 'done))
(define (w32-byte w sh) (w32->fixnum (w32-and (w32-shr w sh) w32-255)))
(define (emit-w32 w)
  (emit-byte (w32-byte w 0)) (emit-byte (w32-byte w 8))
  (emit-byte (w32-byte w 16)) (emit-byte (w32-byte w 24)))
(define (emit-rel8 r)
  (if (and (>= r -128) (<= r 127)) (emit-byte (modulo r 256))
      (asm-error "asm: rel8 out of range")))

; ===========================================================================
; Instruction accessors and sizes.
; ===========================================================================
(define (ihd x) (vector-ref x 0))
(define (a1 x) (vector-ref x 1))
(define (a2 x) (vector-ref x 2))
(define (a3 x) (vector-ref x 3))
(define (insn-size instr)
  (case (ihd instr)
    ((Nop Ret Lodsb Stosb Stosl Movsb Cld Cdq Pushf Popf
      IncR DecR PushR PopR XchgEaxR Db) 1)
    ((RepMovsb RepeCmpsb Int TestALI8 CmpALI8
      MovRR AddRR SubRR CmpRR TestRR XorRR OrRR AndRR XchgRR
      NotR NegR MulR DivR IDivR CallR JmpR PushI8
      MovRM MovMR MovbMR
      JmpS Jz Jnz Jb Jae Jbe Ja Js Jns Jl Jge Jle Jg) 2)
    ((AddI8 OrI8 AdcI8 SbbI8 AndI8 SubI8 XorI8 CmpI8
      ShlI8 ShrI8 SarI8 TestRI8 IMulRR MovRMD MovMDR MovzxRMb LeaRMD) 3)
    ((MovzxRMDb Dd DLabel DConst DNil DObj) 4)
    ((MovRI MovRILabel MovRIConst PushI32 CmpEaxI32 CmpEaxLabel MovRIObj
      Jmp32 Call) 5)
    ((AddI32 AndI32 SubI32 CmpI32 MovRMemL MovMemLR
      Jz32 Jnz32 Jb32 Jae32 Jbe32 Ja32 Jl32 Jge32 Jle32 Jg32) 6)
    (else (asm-error "asm: unknown instruction (size)"))))

; ===========================================================================
; Encoding.
; ===========================================================================
(define (rm00 base reg) (+ (* 8 (reg-num reg)) (reg-num base)))
(define (rm01 base reg) (+ 64 (* 8 (reg-num reg)) (reg-num base)))
(define (rm05 reg) (+ (* 8 (reg-num reg)) 5))
(define (m-rr op x) (eb op) (eb (+ 192 (* 8 (reg-num (a2 x))) (reg-num (a1 x)))))
(define (m-i8 op ext x) (eb op) (eb (+ 192 (* 8 ext) (reg-num (a1 x)))) (eb (bv (a2 x))))
(define (m-un op ext x) (eb op) (eb (+ 192 (* 8 ext) (reg-num (a1 x)))))
(define (m-i32 op ext x) (eb op) (eb (+ 192 (* 8 ext) (reg-num (a1 x)))) (emit-w32 (num-value (a2 x))))
(define (movib x) (eb (+ 184 (reg-num (a1 x)))))
(define (j8 op x pc) (eb op) (emit-rel8 (- (hget (a1 x)) (+ pc 2))))
(define (j32 op x pc) (eb op) (emit-w32 (w32-from-fixnum (- (hget (a1 x)) (+ pc 5)))))
(define (jcc op x pc) (eb 15) (eb op) (emit-w32 (w32-from-fixnum (- (hget (a1 x)) (+ pc 6)))))
(define (emit-instr x pc)
  (case (ihd x)
    ((Nop) (eb 144)) ((Ret) (eb 195)) ((Lodsb) (eb 172)) ((Stosb) (eb 170))
    ((Stosl) (eb 171)) ((Movsb) (eb 164)) ((Cld) (eb 252)) ((Cdq) (eb 153))
    ((Pushf) (eb 156)) ((Popf) (eb 157))
    ((RepMovsb) (eb 243) (eb 164)) ((RepeCmpsb) (eb 243) (eb 166))
    ((Int) (eb 205) (eb (bv (a1 x)))) ((TestALI8) (eb 168) (eb (bv (a1 x))))
    ((CmpALI8) (eb 60) (eb (bv (a1 x))))
    ((IncR) (eb (+ 64 (reg-num (a1 x))))) ((DecR) (eb (+ 72 (reg-num (a1 x)))))
    ((PushR) (eb (+ 80 (reg-num (a1 x))))) ((PopR) (eb (+ 88 (reg-num (a1 x)))))
    ((XchgEaxR) (eb (+ 144 (reg-num (a1 x)))))
    ((MovRR) (m-rr 137 x)) ((AddRR) (m-rr 1 x)) ((SubRR) (m-rr 41 x))
    ((CmpRR) (m-rr 57 x)) ((TestRR) (m-rr 133 x)) ((XorRR) (m-rr 49 x))
    ((OrRR) (m-rr 9 x)) ((AndRR) (m-rr 33 x)) ((XchgRR) (m-rr 135 x))
    ((AddI8) (m-i8 131 0 x)) ((OrI8) (m-i8 131 1 x)) ((AdcI8) (m-i8 131 2 x))
    ((SbbI8) (m-i8 131 3 x)) ((AndI8) (m-i8 131 4 x)) ((SubI8) (m-i8 131 5 x))
    ((XorI8) (m-i8 131 6 x)) ((CmpI8) (m-i8 131 7 x))
    ((ShlI8) (m-i8 193 4 x)) ((ShrI8) (m-i8 193 5 x)) ((SarI8) (m-i8 193 7 x))
    ((NotR) (m-un 247 2 x)) ((NegR) (m-un 247 3 x)) ((MulR) (m-un 247 4 x))
    ((DivR) (m-un 247 6 x)) ((IDivR) (m-un 247 7 x))
    ((TestRI8) (eb 246) (eb (+ 192 (reg-num (a1 x)))) (eb (bv (a2 x))))
    ((IMulRR) (eb 15) (eb 175) (eb (+ 192 (* 8 (reg-num (a1 x))) (reg-num (a2 x)))))
    ((CallR) (eb 255) (eb (+ 208 (reg-num (a1 x)))))
    ((JmpR) (eb 255) (eb (+ 224 (reg-num (a1 x)))))
    ((PushI32) (eb 104) (emit-w32 (num-value (a1 x))))
    ((PushI8) (eb 106) (eb (bv (a1 x))))
    ((AddI32) (m-i32 129 0 x)) ((AndI32) (m-i32 129 4 x))
    ((SubI32) (m-i32 129 5 x)) ((CmpI32) (m-i32 129 7 x))
    ((MovRI) (movib x) (emit-w32 (num-value (a2 x))))
    ((MovRILabel) (movib x) (emit-w32 (vaddr (hget (a2 x)))))
    ((MovRIConst) (movib x) (emit-w32 (w32-add (vaddr (hget (a2 x))) w32-1)))
    ((MovRIObj) (movib x) (emit-w32 (w32-add (vaddr (hget (a2 x))) w32-2)))
    ((MovRM) (eb 139) (eb (rm00 (a2 x) (a1 x))))
    ((MovMR) (eb 137) (eb (rm00 (a1 x) (a2 x))))
    ((MovRMD) (eb 139) (eb (rm01 (a2 x) (a1 x))) (eb (bv (a3 x))))
    ((MovMDR) (eb 137) (eb (rm01 (a1 x) (a3 x))) (eb (bv (a2 x))))
    ((MovzxRMb) (eb 15) (eb 182) (eb (rm00 (a2 x) (a1 x))))
    ((MovzxRMDb) (eb 15) (eb 182) (eb (rm01 (a2 x) (a1 x))) (eb (bv (a3 x))))
    ((MovbMR) (eb 136) (eb (rm00 (a1 x) (a2 x))))
    ((LeaRMD) (eb 141) (eb (rm01 (a2 x) (a1 x))) (eb (bv (a3 x))))
    ((MovRMemL) (eb 139) (eb (rm05 (a1 x))) (emit-w32 (vaddr (hget (a2 x)))))
    ((MovMemLR) (eb 137) (eb (rm05 (a2 x))) (emit-w32 (vaddr (hget (a1 x)))))
    ((CmpEaxI32) (eb 61) (emit-w32 (num-value (a1 x))))
    ((CmpEaxLabel) (eb 61) (emit-w32 (vaddr (hget (a1 x)))))
    ((Db) (eb (bv (a1 x))))
    ((Dd) (emit-w32 (num-value (a1 x))))
    ((DLabel) (emit-w32 (vaddr (hget (a1 x)))))
    ((DConst) (emit-w32 (w32-add (vaddr (hget (a1 x))) w32-1)))
    ((DObj) (emit-w32 (w32-add (vaddr (hget (a1 x))) w32-2)))
    ((DNil) (eb 1) (eb 0) (eb 0) (eb 0))
    ((JmpS) (j8 235 x pc)) ((Jz) (j8 116 x pc)) ((Jnz) (j8 117 x pc))
    ((Jb) (j8 114 x pc)) ((Jae) (j8 115 x pc)) ((Jbe) (j8 118 x pc))
    ((Ja) (j8 119 x pc)) ((Js) (j8 120 x pc)) ((Jns) (j8 121 x pc))
    ((Jl) (j8 124 x pc)) ((Jge) (j8 125 x pc)) ((Jle) (j8 126 x pc))
    ((Jg) (j8 127 x pc))
    ((Jmp32) (j32 233 x pc)) ((Call) (j32 232 x pc))
    ((Jz32) (jcc 132 x pc)) ((Jnz32) (jcc 133 x pc)) ((Jb32) (jcc 130 x pc))
    ((Jae32) (jcc 131 x pc)) ((Jbe32) (jcc 134 x pc)) ((Ja32) (jcc 135 x pc))
    ((Jl32) (jcc 140 x pc)) ((Jge32) (jcc 141 x pc)) ((Jle32) (jcc 142 x pc))
    ((Jg32) (jcc 143 x pc))
    (else (asm-error "asm: unknown instruction (emit)"))))
(define (pad4 pc) (remainder (- 4 (remainder pc 4)) 4))
(define (pad8 pc) (remainder (- 8 (remainder pc 8)) 8))

; ===========================================================================
; Spine walk.  Both passes share a NILADIC walk over the (Ins ...) chain: all
; cursor / pc state is in globals, so host-heap-reset! at each batch boundary
; frees the per-instruction transient without pinning anything.  g-phase = 1
; (assign label offsets) or 2 (emit).  On (RuntimeCode)/(RuntimeData), we take a
; side excursion into the runtime buffer R.
; ===========================================================================
(define g-phase 0) (define g-pc 0) (define g-k 0) (define g-floor #f) (define read-floor #f)
(define g-sp-head #f)
(define (batch-reset!)
  (set! g-k (+ g-k 1))
  (if (= (remainder g-k 64) 0) (host-heap-reset! g-floor)))
(define (proc-instr instr)
  (if (= g-phase 1)
      (case (ihd instr)
        ((Label) (st-put! (a1 instr) g-pc))
        ((Align4) (set! g-pc (+ g-pc (pad4 g-pc))))
        ((Align8) (set! g-pc (+ g-pc (pad8 g-pc))))
        (else (set! g-pc (+ g-pc (insn-size instr)))))
      (case (ihd instr)
        ((Label) 'skip)
        ((Align4) (let ((p (pad4 g-pc))) (emit-zeros p) (set! g-pc (+ g-pc p))))
        ((Align8) (let ((p (pad8 g-pc))) (emit-zeros p) (set! g-pc (+ g-pc p))))
        (else (emit-instr instr g-pc) (set! g-pc (+ g-pc (insn-size instr)))))))
(define (walk-spine)
  (batch-reset!)
  (let ((h g-sp-head))
    (cond
      ((eq? h 'Ins) (proc-instr (read-datum)) (set! g-sp-head (next-tail-head)) (walk-spine))
      ((eq? h 'RuntimeCode) (run-excursion 0) (set! g-sp-head (next-tail-head)) (walk-spine))
      ((eq? h 'RuntimeData) (run-excursion rd-start) (set! g-sp-head (next-tail-head)) (walk-spine))
      (else 'done))))                      ; End -> stop
(define (next-tail-head)
  (skip-ws)
  (if (= (pk) 40) (begin (nx) (read-atom)) (read-atom)))
; Excursion into R from the given start offset, processing (...) instructions
; until RTSPLIT (code section) or end (data section), then restore the P cursor.
(define g-save-pos 0)
(define (run-excursion start)
  (set! g-save-pos cpos)
  (set! cbuf R) (set! clen rlen) (set! cpos start)
  (run-loop)
  (set! cbuf P) (set! clen plen) (set! cpos g-save-pos))
; No reset here: run-loop is called with walk-spine's frame live above the
; floor, so a reset would free it.  The runtime is small (~1500 instrs); its
; transient is reclaimed by the next walk-spine batch-reset!.
(define (run-loop)
  (skip-ws)
  (if (= (pk) 40)
      (begin (proc-instr (read-datum)) (run-loop))
      (if (< (pk) 0) 'done
          (begin (read-atom)              ; consume RTSPLIT
                 (if (< rd-start 0) (set! rd-start cpos))))))

; ===========================================================================
; Header parse (advances the P cursor past  (Assemble (Program entry bss ),
; leaving g-sp-head at the first code head).  Re-run each pass.
; ===========================================================================
(define g-entry #f) (define g-bss #f) (define g-codesize 0)
(define (parse-header!)
  (set! cbuf P) (set! clen plen) (set! cpos 0)
  (expect-lparen) (expect-sym 'Assemble)
  (expect-lparen) (expect-sym 'Program)
  (set! g-entry (read-datum))
  (expect-lparen)
  (let ((h (read-atom)))
    (if (or (eq? h 'X8) (eq? h 'Small))
        (begin (set! g-bss (num-value (read-numtail h)))
               (expect-lparen) (set! g-sp-head (read-atom)))
        (begin (set! g-bss (w32-from-fixnum 0))
               (set! g-sp-head h)))))
(define (read-numtail h) (list->vector (cons h (reverse (read-elems '())))))

; ===========================================================================
; ELF header (transliteration of (ElfHeader entryoff codesize bss)).
; ===========================================================================
(define header-a (list 127 69 76 70 1 1 1 0 0 0 0 0 0 0 0 0  2 0 3 0 1 0 0 0))
(define header-b (list 52 0 0 0 0 0 0 0 0 0 0 0))
(define header-c (list 52 0 32 0 1 0 0 0 0 0 0 0))
(define header-d (list 1 0 0 0 0 0 0 0))
(define header-e (list 0 128 4 8 0 128 4 8))
(define header-f (list 7 0 0 0 0 16 0 0))
(define header-g (list 0 0 0 0))
(define (emit-header)
  (emit-bytes header-a)
  (emit-w32 (vaddr (hget g-entry)))
  (emit-bytes header-b) (emit-bytes header-c)
  (emit-bytes header-d) (emit-bytes header-e)
  (emit-w32 (w32-add w32-88 (w32-from-fixnum g-codesize)))
  (emit-w32 (w32-add (w32-add w32-88 (w32-from-fixnum g-codesize)) g-bss))
  (emit-bytes header-f) (emit-bytes header-g))

; ===========================================================================
; Driver.
; ===========================================================================
(define (init-vocab!)
  (for-each vocab-add!
    (list "Assemble" "Program" "Ins" "End" "Label" "Align4" "Align8"
          "RuntimeCode" "RuntimeData" "RTSPLIT" "X8" "Small"
          "EAX" "ECX" "EDX" "EBX" "ESP" "EBP" "ESI" "EDI"
          "Nop" "Ret" "Lodsb" "Stosb" "Stosl" "Movsb" "Cld" "Cdq" "Pushf" "Popf"
          "IncR" "DecR" "PushR" "PopR" "XchgEaxR" "Db"
          "RepMovsb" "RepeCmpsb" "Int" "TestALI8" "CmpALI8"
          "MovRR" "AddRR" "SubRR" "CmpRR" "TestRR" "XorRR" "OrRR" "AndRR" "XchgRR"
          "NotR" "NegR" "MulR" "DivR" "IDivR" "CallR" "JmpR" "PushI8"
          "MovRM" "MovMR" "MovbMR"
          "JmpS" "Jz" "Jnz" "Jb" "Jae" "Jbe" "Ja" "Js" "Jns" "Jl" "Jge" "Jle" "Jg"
          "AddI8" "OrI8" "AdcI8" "SbbI8" "AndI8" "SubI8" "XorI8" "CmpI8"
          "ShlI8" "ShrI8" "SarI8" "TestRI8" "IMulRR" "MovRMD" "MovMDR" "MovzxRMb" "LeaRMD"
          "MovzxRMDb" "Dd" "DLabel" "DConst" "DNil" "DObj"
          "MovRI" "MovRILabel" "MovRIConst" "PushI32" "CmpEaxI32" "CmpEaxLabel" "MovRIObj"
          "Jmp32" "Call"
          "AddI32" "AndI32" "SubI32" "CmpI32" "MovRMemL" "MovMemLR"
          "Jz32" "Jnz32" "Jb32" "Jae32" "Jbe32" "Ja32" "Jl32" "Jge32" "Jle32" "Jg32")))
(define (init!)
  (set! w32-1 (w32-from-fixnum 1))
  (set! w32-2 (w32-from-fixnum 2))
  (set! w32-88 (w32-from-fixnum 88))
  (set! w32-255 (w32-from-fixnum 255))
  (set! w32-vbase (w32-or (w32-shl (w32-from-fixnum 2052) 16) (w32-from-fixnum 32856)))
  (init-vocab!)
  (set! P (make-string P-CAP))
  (set! R (make-string R-CAP))
  (set! chunk (make-string CHUNK))
  (set! t-koff (make-vector TSZ -1))
  (set! t-klen (make-vector TSZ 0))
  (set! t-val (make-vector TSZ 0))
  (set! keybuf (make-string KEYBUF-CAP)))
(define (main)
  (init!)
  (set! read-floor (w32-add (host-heap-mark) (w32-from-fixnum 64)))
  (slurp-runtime!)                         ; fill R (mutates pre-alloc buffer)
  (slurp-stdin!)                           ; fill P
  (host-heap-reset! read-floor)
  ; pass1: assign label offsets, compute code size
  (set! g-phase 1) (set! g-pc 0) (set! g-k 0) (set! g-floor read-floor)
  (parse-header!) (walk-spine)
  (set! g-codesize g-pc)
  (host-heap-reset! read-floor)
  ; pass2
  (set! g-out (make-string (+ 88 g-codesize))) (set! g-out-pos 0)
  (parse-header!)                          ; re-read entry/bss
  (emit-header)
  (set! g-phase 2) (set! g-pc 0) (set! g-k 0)
  (set! g-floor (w32-add (host-heap-mark) (w32-from-fixnum 64)))   ; above g-out
  (walk-spine)
  (sys-write 1 g-out g-out-pos))
(main)
