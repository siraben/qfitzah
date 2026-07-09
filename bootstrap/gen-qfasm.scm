; gen-qfasm.scm -- dialect (rsc) generator for bootstrap/qfasm.qf1 (the seed-hosted assembler).
; Emits bootstrap/qfasm.qf1 (the seed-hosted i386 assembler), BYTE-IDENTICAL to
; the Python.  Build/run with tools/regen.sh (see that script).

; ---------------------------------------------------------------------------
; Output helpers.
; ---------------------------------------------------------------------------
(define (pl s) (begin (display s) (newline)))
(define (rule pat tmpl) (pl (string-append pat " " tmpl)))
(define (section title) (begin (pl "") (pl (string-append "; " title))))

(define HEX "0123456789ABCDEF")
(define (hd i) (string (string-ref HEX i)))          ; one uppercase hex digit
(define (hex2 n) (string-append (hd (quotient n 16)) (hd (remainder n 16))))
(define (ns n) (number->string n))

; REGS with their encoding numbers.
(define REGS
  (list (cons "EAX" 0) (cons "ECX" 1) (cons "EDX" 2) (cons "EBX" 3)
        (cons "ESP" 4) (cons "EBP" 5) (cons "ESI" 6) (cons "EDI" 7)))
(define (rn p) (cdr p))
(define (rname p) (car p))

; ---------------------------------------------------------------------------
; Fact tables.
; ---------------------------------------------------------------------------
(define (for-range lo hi f)   ; f over lo..hi inclusive
  (if (> lo hi) #f (begin (f lo) (for-range (+ lo 1) hi f))))

(define (build-facts)
  (section "Single-nybble add with carry in: (AD carry a b) -> (P sum carry').")
  (for-each
    (lambda (cn)
      (let ((cin (car cn)) (cname (cdr cn)))
        (for-range 0 15
          (lambda (a)
            (for-range 0 15
              (lambda (b)
                (let ((s (+ a b cin)))
                  (rule (string-append "(AD " cname " " (hd a) " " (hd b) ")")
                        (string-append "(P " (hd (remainder s 16)) " "
                          (if (>= s 16) "I" "O") ")")))))))))
    (list (cons 0 "O") (cons 1 "I")))

  (section "Nybble complement: (ND d) -> 15 - d.")
  (for-range 0 15 (lambda (d) (rule (string-append "(ND " (hd d) ")") (hd (- 15 d)))))

  (section "Nybble pair to byte atom: (HB hi lo) -> byte.")
  (for-range 0 15
    (lambda (hi)
      (for-range 0 15
        (lambda (lo)
          (rule (string-append "(HB " (hd hi) " " (hd lo) ")")
                (string-append (hd hi) (hd lo)))))))

  (section "ModRM mod=11 (register-register): (RM11 reg rm) -> byte.")
  (for-each
    (lambda (r)
      (for-each
        (lambda (m)
          (rule (string-append "(RM11 " (rname r) " " (rname m) ")")
                (hex2 (+ 192 (* 8 (rn r)) (rn m)))))
        REGS))
    REGS)

  (section "ModRM mod=00 ([base]): (RM00 base reg) -> byte (no ESP/EBP base).")
  (for-each
    (lambda (b)
      (if (or (string=? (rname b) "ESP") (string=? (rname b) "EBP"))
          #f
          (for-each
            (lambda (r)
              (rule (string-append "(RM00 " (rname b) " " (rname r) ")")
                    (hex2 (+ (* 8 (rn r)) (rn b)))))
            REGS)))
    REGS)

  (section "ModRM mod=01 ([base+disp8]): (RM01 base reg) -> byte (no ESP base).")
  (for-each
    (lambda (b)
      (if (string=? (rname b) "ESP")
          #f
          (for-each
            (lambda (r)
              (rule (string-append "(RM01 " (rname b) " " (rname r) ")")
                    (hex2 (+ 64 (* 8 (rn r)) (rn b)))))
            REGS)))
    REGS)

  (section "ModRM mod=00 rm=101 (absolute disp32): (RM05 reg) -> byte.")
  (for-each
    (lambda (r) (rule (string-append "(RM05 " (rname r) ")") (hex2 (+ (* 8 (rn r)) 5))))
    REGS)

  (section "Opcode-extension ModRM mod=11: (RMX ext reg) -> byte.")
  (for-range 0 7
    (lambda (n)
      (for-each
        (lambda (r) (rule (string-append "(RMX " (ns n) " " (rname r) ")")
                          (hex2 (+ 192 (* 8 n) (rn r)))))
        REGS)))

  (section "One-byte opcode+reg encodings.")
  (for-each
    (lambda (bn)
      (let ((base (car bn)) (name (cdr bn)))
        (for-each
          (lambda (r) (rule (string-append "(" name " " (rname r) ")") (hex2 (+ base (rn r)))))
          REGS)))
    (list (cons 64 "IncB") (cons 72 "DecB") (cons 80 "PushB")
          (cons 88 "PopB") (cons 184 "MovIB") (cons 144 "XchgAB")))

  (section "Alignment pad from the low nybble: (PadDig4 d), (PadDig8 d).")
  (for-range 0 15
    (lambda (d) (rule (string-append "(PadDig4 " (hd d) ")") (hd (remainder (- 4 (remainder d 4)) 4)))))
  (for-range 0 15
    (lambda (d) (rule (string-append "(PadDig8 " (hd d) ")") (hd (remainder (- 8 (remainder d 8)) 8)))))

  (section "Rel8 range guards: high nybble of an in-range offset byte.")
  (for-range 0 7 (lambda (d) (rule (string-append "(R8P " (hd d) ")") "OK")))
  (for-range 8 15 (lambda (d) (rule (string-append "(R8N " (hd d) ")") "OK"))))

; ---------------------------------------------------------------------------
; 32-bit arithmetic over nybble lists.
; ---------------------------------------------------------------------------
(define (pairs-from i)      ; " a{i} b{i} ... a7 b7"
  (if (> i 7) "" (string-append " a" (ns i) " b" (ns i) (pairs-from (+ i 1)))))
(define (sums-help j hi)    ; "s{j} ... s{hi} " ascending, each with trailing space
  (if (> j hi) "" (string-append "s" (ns j) " " (sums-help (+ j 1) hi))))
(define (join-sums-help j hi)  ; "s{j} ... s{hi}" joined by single spaces
  (if (> j hi) ""
      (if (= j hi) (string-append "s" (ns j))
          (string-append "s" (ns j) " " (join-sums-help (+ j 1) hi)))))

(define (build-arith)
  (section "Number sugar: big-endian X8 literals and small constants.")
  (rule "(X8 a b c d e f g h)" "(N h g f e d c b a)")
  (for-range 0 15
    (lambda (d) (rule (string-append "(Small " (hd d) ")")
                      (string-append "(N " (hd d) " 0 0 0 0 0 0 0)"))))

  (section "32-bit add (wraps mod 2^32): digit-chained through (AD ...).")
  (rule "(Add32 (N a0 a1 a2 a3 a4 a5 a6 a7) (N b0 b1 b2 b3 b4 b5 b6 b7))"
        (string-append "(A1 (AD O a0 b0)" (pairs-from 1) ")"))
  (for-range 1 7
    (lambda (i)
      (rule (string-append "(A" (ns i) " " (sums-help 0 (- i 2))
                           "(P s" (ns (- i 1)) " c)" (pairs-from i) ")")
            (string-append "(A" (ns (+ i 1)) " " (join-sums-help 0 (- i 1))
                           " (AD c a" (ns i) " b" (ns i) ")" (pairs-from (+ i 1)) ")"))))
  (rule "(A8 s0 s1 s2 s3 s4 s5 s6 (P s7 c))" "(N s0 s1 s2 s3 s4 s5 s6 s7)")

  (section "Negate and subtract.")
  (rule "(Neg32 (N a0 a1 a2 a3 a4 a5 a6 a7))"
        "(Add32 (N (ND a0) (ND a1) (ND a2) (ND a3) (ND a4) (ND a5) (ND a6) (ND a7)) (Small 1))")
  (rule "(Sub32 x y)" "(Add32 x (Neg32 y))")

  (section "Byte emission from numbers.")
  (rule "(LEB (N d0 d1 d2 d3 d4 d5 d6 d7))"
        "(Bytes (HB d1 d0) (HB d3 d2) (HB d5 d4) (HB d7 d6))")
  (rule "(LowByte (N d0 d1 d2 d3 d4 d5 d6 d7))" "(HB d1 d0)")

  (section "Checked rel8: in-range offsets only, else the term stays stuck.")
  (rule "(Rel8 (N d0 d1 0 0 0 0 0 0))" "(R8Ck (R8P d1) (HB d1 d0))")
  (rule "(Rel8 (N d0 d1 F F F F F F))" "(R8Ck (R8N d1) (HB d1 d0))")
  (rule "(R8Ck OK b)" "b")

  (section "Alignment padding.")
  (rule "(Pad4 (N d0 d1 d2 d3 d4 d5 d6 d7))" "(Small (PadDig4 d0))")
  (rule "(Pad8 (N d0 d1 d2 d3 d4 d5 d6 d7))" "(Small (PadDig8 d0))")
  (for-range 0 7
    (lambda (k)
      (rule (string-append "(PadOut (N " (ns k) " 0 0 0 0 0 0 0))")
            (string-append "(Bytes" (rep-str " 00" k) ")")))))

(define (rep-str s n) (if (= n 0) "" (string-append s (rep-str s (- n 1)))))

; ---------------------------------------------------------------------------
; Instruction spec: (head size body).  head already includes its parens/args.
; ---------------------------------------------------------------------------
(define (mk h s b) (list h s b))
(define (ins-head x) (car x))
(define (ins-size x) (cadr x))
(define (ins-body x) (caddr x))

(define INSTRUCTIONS
  (list
    (mk "(Nop)" 1 "90") (mk "(Ret)" 1 "C3") (mk "(Lodsb)" 1 "AC")
    (mk "(Stosb)" 1 "AA") (mk "(Stosl)" 1 "AB") (mk "(Movsb)" 1 "A4")
    (mk "(Cld)" 1 "FC") (mk "(Cdq)" 1 "99") (mk "(Pushf)" 1 "9C")
    (mk "(Popf)" 1 "9D")
    (mk "(RepMovsb)" 2 "F3 A4") (mk "(RepeCmpsb)" 2 "F3 A6")
    (mk "(Int b)" 2 "CD b") (mk "(TestALI8 b)" 2 "A8 b") (mk "(CmpALI8 b)" 2 "3C b")
    (mk "(IncR r)" 1 "(IncB r)") (mk "(DecR r)" 1 "(DecB r)")
    (mk "(PushR r)" 1 "(PushB r)") (mk "(PopR r)" 1 "(PopB r)")
    (mk "(XchgEaxR r)" 1 "(XchgAB r)")
    (mk "(MovRR d s)" 2 "89 (RM11 s d)") (mk "(AddRR d s)" 2 "01 (RM11 s d)")
    (mk "(SubRR d s)" 2 "29 (RM11 s d)") (mk "(CmpRR d s)" 2 "39 (RM11 s d)")
    (mk "(TestRR d s)" 2 "85 (RM11 s d)") (mk "(XorRR d s)" 2 "31 (RM11 s d)")
    (mk "(OrRR d s)" 2 "09 (RM11 s d)") (mk "(AndRR d s)" 2 "21 (RM11 s d)")
    (mk "(XchgRR d s)" 2 "87 (RM11 s d)")
    (mk "(AddI8 r b)" 3 "83 (RMX 0 r) b") (mk "(OrI8 r b)" 3 "83 (RMX 1 r) b")
    (mk "(AdcI8 r b)" 3 "83 (RMX 2 r) b") (mk "(SbbI8 r b)" 3 "83 (RMX 3 r) b")
    (mk "(AndI8 r b)" 3 "83 (RMX 4 r) b") (mk "(SubI8 r b)" 3 "83 (RMX 5 r) b")
    (mk "(XorI8 r b)" 3 "83 (RMX 6 r) b") (mk "(CmpI8 r b)" 3 "83 (RMX 7 r) b")
    (mk "(ShlI8 r b)" 3 "C1 (RMX 4 r) b") (mk "(ShrI8 r b)" 3 "C1 (RMX 5 r) b")
    (mk "(SarI8 r b)" 3 "C1 (RMX 7 r) b")
    (mk "(NotR r)" 2 "F7 (RMX 2 r)") (mk "(NegR r)" 2 "F7 (RMX 3 r)")
    (mk "(MulR r)" 2 "F7 (RMX 4 r)") (mk "(DivR r)" 2 "F7 (RMX 6 r)")
    (mk "(IDivR r)" 2 "F7 (RMX 7 r)")
    (mk "(TestRI8 r b)" 3 "F6 (RMX 0 r) b")
    (mk "(IMulRR d s)" 3 "0F AF (RM11 d s)")
    (mk "(CallR r)" 2 "FF (RMX 2 r)") (mk "(JmpR r)" 2 "FF (RMX 4 r)")
    (mk "(PushI32 x)" 5 "68 (LEB x)") (mk "(PushI8 b)" 2 "6A b")
    (mk "(AddI32 r x)" 6 "81 (RMX 0 r) (LEB x)")
    (mk "(AndI32 r x)" 6 "81 (RMX 4 r) (LEB x)")
    (mk "(SubI32 r x)" 6 "81 (RMX 5 r) (LEB x)")
    (mk "(CmpI32 r x)" 6 "81 (RMX 7 r) (LEB x)")
    (mk "(MovRI r x)" 5 "(MovIB r) (LEB x)")
    (mk "(MovRILabel r l)" 5 "(MovIB r) (LEB (VAddr (Lookup l sym)))")
    (mk "(MovRIConst r l)" 5 "(MovIB r) (LEB (Add32 (VAddr (Lookup l sym)) (Small 1)))")
    (mk "(MovRM r b)" 2 "8B (RM00 b r)") (mk "(MovMR b r)" 2 "89 (RM00 b r)")
    (mk "(MovRMD r b d)" 3 "8B (RM01 b r) d") (mk "(MovMDR b d r)" 3 "89 (RM01 b r) d")
    (mk "(MovzxRMb r b)" 3 "0F B6 (RM00 b r)")
    (mk "(MovzxRMDb r b d)" 4 "0F B6 (RM01 b r) d")
    (mk "(MovbMR b r)" 2 "88 (RM00 b r)") (mk "(LeaRMD r b d)" 3 "8D (RM01 b r) d")
    (mk "(MovRMemL r l)" 6 "8B (RM05 r) (LEB (VAddr (Lookup l sym)))")
    (mk "(MovMemLR l r)" 6 "89 (RM05 r) (LEB (VAddr (Lookup l sym)))")
    (mk "(CmpEaxI32 x)" 5 "3D (LEB x)")
    (mk "(CmpEaxLabel l)" 5 "3D (LEB (VAddr (Lookup l sym)))")
    (mk "(Db b)" 1 "b") (mk "(Dd x)" 4 "(LEB x)")
    (mk "(DLabel l)" 4 "(LEB (VAddr (Lookup l sym)))")
    (mk "(DConst l)" 4 "(LEB (Add32 (VAddr (Lookup l sym)) (Small 1)))")
    (mk "(DNil)" 4 "01 00 00 00")))

; (name . opcode) jump tables.
(define SHORT-JUMPS
  (list (cons "JmpS" "EB") (cons "Jz" "74") (cons "Jnz" "75") (cons "Jb" "72")
        (cons "Jae" "73") (cons "Jbe" "76") (cons "Ja" "77") (cons "Js" "78")
        (cons "Jns" "79") (cons "Jl" "7C") (cons "Jge" "7D") (cons "Jle" "7E")
        (cons "Jg" "7F")))
(define LONG-JUMPS (list (cons "Jmp32" "E9") (cons "Call" "E8")))
(define LONG-CC
  (list (cons "Jz32" "84") (cons "Jnz32" "85") (cons "Jb32" "82") (cons "Jae32" "83")
        (cons "Jbe32" "86") (cons "Ja32" "87") (cons "Jl32" "8C") (cons "Jge32" "8D")
        (cons "Jle32" "8E") (cons "Jg32" "8F")))

; ---------------------------------------------------------------------------
; Rule-emitting passes.
; ---------------------------------------------------------------------------
(define (build-rest)
  (section "Symbol table: keys are arbitrary terms, matched structurally.")
  (rule "(Lookup name (Bind other pc rest))" "(Lookup name rest)")
  (rule "(Lookup name (Bind name pc rest))" "pc")

  (section "Virtual addresses and ELF layout arithmetic.")
  (rule "(VBase)" "(X8 0 8 0 4 8 0 5 8)")
  (rule "(VAddr off)" "(Add32 (VBase) off)")
  (rule "(HdrSize)" "(X8 0 0 0 0 0 0 5 8)")
  (rule "(FileSz size)" "(Add32 (HdrSize) size)")

  (section "Instruction sizes.")
  (rule "(Size (Label name))" "(Small 0)")
  (for-each
    (lambda (x) (rule (string-append "(Size " (ins-head x) ")")
                      (string-append "(Small " (hd (ins-size x)) ")")))
    INSTRUCTIONS)
  (for-each (lambda (j) (rule (string-append "(Size (" (car j) " l))") "(Small 2)")) SHORT-JUMPS)
  (for-each (lambda (j) (rule (string-append "(Size (" (car j) " l))") "(Small 5)")) LONG-JUMPS)
  (for-each (lambda (j) (rule (string-append "(Size (" (car j) " l))") "(Small 6)")) LONG-CC)

  (section "Layout pass: label addresses as code offsets.")
  (rule "(Pass1 End pc sym)" "sym")
  (rule "(Pass1 (Ins instr rest) pc sym)" "(Pass1 rest (Add32 pc (Size instr)) sym)")
  (rule "(Pass1 (Ins (Label name) rest) pc sym)" "(Pass1 rest pc (Bind name pc sym))")
  (rule "(Pass1 (Ins (Align4) rest) pc sym)" "(Pass1 rest (Add32 pc (Pad4 pc)) sym)")
  (rule "(Pass1 (Ins (Align8) rest) pc sym)" "(Pass1 rest (Add32 pc (Pad8 pc)) sym)")

  (section "Code size pass.")
  (rule "(CodeSize End pc)" "pc")
  (rule "(CodeSize (Ins instr rest) pc)" "(CodeSize rest (Add32 pc (Size instr)))")
  (rule "(CodeSize (Ins (Align4) rest) pc)" "(CodeSize rest (Add32 pc (Pad4 pc)))")
  (rule "(CodeSize (Ins (Align8) rest) pc)" "(CodeSize rest (Add32 pc (Pad8 pc)))")

  (section "Emission pass.")
  (rule "(Pass2 End pc sym)" "(Bytes)")
  (rule "(Pass2 (Ins (Label name) rest) pc sym)" "(Pass2 rest pc sym)")
  (rule "(Pass2 (Ins (Align4) rest) pc sym)"
        "(Bytes (PadOut (Pad4 pc)) (Pass2 rest (Add32 pc (Pad4 pc)) sym))")
  (rule "(Pass2 (Ins (Align8) rest) pc sym)"
        "(Bytes (PadOut (Pad8 pc)) (Pass2 rest (Add32 pc (Pad8 pc)) sym))")
  (for-each
    (lambda (x)
      (rule (string-append "(Pass2 (Ins " (ins-head x) " rest) pc sym)")
            (string-append "(Bytes " (ins-body x)
              " (Pass2 rest (Add32 pc (Small " (hd (ins-size x)) ")) sym))")))
    INSTRUCTIONS)
  (for-each
    (lambda (j)
      (rule (string-append "(Pass2 (Ins (" (car j) " l) rest) pc sym)")
            (string-append "(Bytes " (cdr j)
              " (Rel8 (Sub32 (Lookup l sym) (Add32 pc (Small 2)))) (Pass2 rest (Add32 pc (Small 2)) sym))")))
    SHORT-JUMPS)
  (for-each
    (lambda (j)
      (rule (string-append "(Pass2 (Ins (" (car j) " l) rest) pc sym)")
            (string-append "(Bytes " (cdr j)
              " (LEB (Sub32 (Lookup l sym) (Add32 pc (Small 5)))) (Pass2 rest (Add32 pc (Small 5)) sym))")))
    LONG-JUMPS)
  (for-each
    (lambda (j)
      (rule (string-append "(Pass2 (Ins (" (car j) " l) rest) pc sym)")
            (string-append "(Bytes 0F " (cdr j)
              " (LEB (Sub32 (Lookup l sym) (Add32 pc (Small 6)))) (Pass2 rest (Add32 pc (Small 6)) sym))")))
    LONG-CC)

  (section "ELF emission: one RWE LOAD segment, optional extra bss memory.")
  (rule "(ElfHeader entryoff codesize bss)"
        "(Bytes 7F 45 4C 46 01 01 01 00 00 00 00 00 00 00 00 00 02 00 03 00 01 00 00 00 (LEB (VAddr entryoff)) 34 00 00 00 00 00 00 00 00 00 00 00 34 00 20 00 01 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 80 04 08 00 80 04 08 (LEB (FileSz codesize)) (LEB (Add32 (FileSz codesize) bss)) 07 00 00 00 00 10 00 00 00 00 00 00)")

  (section "Top level.")
  (rule "(Assemble (Program entry code))" "(Assemble (Program entry (Small 0) code))")
  (rule "(Assemble (Program entry bss code))"
        "(Asm2 entry bss code (Pass1 code (Small 0) Empty) (CodeSize code (Small 0)))")
  (rule "(Asm2 entry bss code sym size)"
        "(Bytes (ElfHeader (Lookup entry sym) size bss) (Pass2 code (Small 0) sym))"))

(define (main)
  (begin
    (pl "; General Qfitzah-hosted i386 assembler (Stage 1).")
    (pl "; GENERATED by bootstrap/gen-qfasm.scm -- do not edit by hand.")
    (pl "; Numbers are little-endian nybble lists (N d0 ... d7); see the")
    (pl "; generator for the architecture notes.")
    (build-facts)
    (build-arith)
    (build-rest)))

(main)
