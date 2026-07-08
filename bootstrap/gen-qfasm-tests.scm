; gen-qfasm-tests.scm -- dialect (rsc) reimplementation of
; tools/generate_qfasm_tests.py.  Reproduces CPython's Mersenne Twister
; (MT19937) and the independent i386 byte model so the committed
; tests/cases/qfasm-{exit42,arith,big} fixtures are byte-identical.
;
; Multi-file generator: selects one artifact by argv:
;   exit42-qfasm exit42-hex exit42-status
;   arith-qfasm  arith-out
;   big-qfasm    big-hex    big-status
; (see tools/regen.sh / the gen-verify gate).

(define (k n) (w32-from-fixnum n))
(define (w32-hex b3 b2 b1 b0)
  (w32-or (w32-or (w32-shl (k b3) 24) (w32-shl (k b2) 16))
          (w32-or (w32-shl (k b1) 8) (k b0))))

; ---------------------------------------------------------------------------
; MT19937.
; ---------------------------------------------------------------------------
(define N 624)
(define MT (make-vector 624 #f))
(define mti 625)
(define (mt-ref i) (vector-ref MT i))
(define (mt-set! i v) (vector-set! MT i v))

(define C1812433253 (w32-hex 108 7 137 101))     ; 0x6C078965
(define C1664525     (w32-hex 0 25 102 13))      ; 0x0019660D
(define C1566083941  (w32-hex 93 88 139 101))    ; 0x5D588B65
(define C19650218    (w32-hex 1 43 214 170))     ; 0x012BD6AA
(define MAG1         (w32-hex 153 8 176 223))    ; 0x9908B0DF
(define UPPER        (w32-hex 128 0 0 0))        ; 0x80000000
(define LOWER        (w32-hex 127 255 255 255))  ; 0x7FFFFFFF
(define TMASKB       (w32-hex 157 44 86 128))    ; 0x9D2C5680
(define TMASKC       (w32-hex 239 198 0 0))      ; 0xEFC60000
(define W0           (k 0))

(define (init-genrand s)
  (begin (mt-set! 0 s) (ig-loop 1) (set! mti 624)))
(define (ig-loop i)
  (if (= i 624) #f
      (begin
        (let ((p (mt-ref (- i 1))))
          (mt-set! i (w32-add (w32-mul C1812433253 (w32-xor p (w32-shr p 30))) (k i))))
        (ig-loop (+ i 1)))))

; init_by_array with a single-word key (seed(7)/seed(42) both do this).
(define (init-by-array key0)
  (begin
    (init-genrand C19650218)
    (iba2 (iba1 1 0 624 key0) 623)
    (mt-set! 0 UPPER)))
(define (iba1 i j kk key0)
  (if (= kk 0) i
      (let ((p (mt-ref (- i 1))))
        (begin
          (mt-set! i (w32-add (w32-add
                        (w32-xor (mt-ref i) (w32-mul (w32-xor p (w32-shr p 30)) C1664525))
                        key0) (k j)))
          (let ((i2 (+ i 1)) (j2 (+ j 1)))
            (let ((i3 (if (>= i2 624) (begin (mt-set! 0 (mt-ref 623)) 1) i2))
                  (j3 (if (>= j2 1) 0 j2)))
              (iba1 i3 j3 (- kk 1) key0)))))))
(define (iba2 i kk)
  (if (= kk 0) #f
      (let ((p (mt-ref (- i 1))))
        (begin
          (mt-set! i (w32-sub
                       (w32-xor (mt-ref i) (w32-mul (w32-xor p (w32-shr p 30)) C1566083941))
                       (k i)))
          (let ((i2 (+ i 1)))
            (let ((i3 (if (>= i2 624) (begin (mt-set! 0 (mt-ref 623)) 1) i2)))
              (iba2 i3 (- kk 1))))))))

(define (mag y) (if (= (w32->fixnum (w32-and y (k 1))) 1) MAG1 W0))
(define (twist-at kk kk2)
  (let ((y (w32-or (w32-and (mt-ref kk) UPPER) (w32-and (mt-ref (+ kk 1)) LOWER))))
    (mt-set! kk (w32-xor (w32-xor (mt-ref kk2) (w32-shr y 1)) (mag y)))))
(define (twist-a kk) (if (> kk 226) #f (begin (twist-at kk (+ kk 397)) (twist-a (+ kk 1)))))
(define (twist-b kk) (if (> kk 622) #f (begin (twist-at kk (- (+ kk 397) 624)) (twist-b (+ kk 1)))))
(define (generate)
  (begin
    (twist-a 0)
    (twist-b 227)
    (let ((y (w32-or (w32-and (mt-ref 623) UPPER) (w32-and (mt-ref 0) LOWER))))
      (mt-set! 623 (w32-xor (w32-xor (mt-ref 396) (w32-shr y 1)) (mag y))))
    (set! mti 0)))

(define (genrand)
  (begin
    (if (>= mti 624) (generate) #f)
    (let ((y (mt-ref mti)))
      (begin
        (set! mti (+ mti 1))
        (let* ((y1 (w32-xor y (w32-shr y 11)))
               (y2 (w32-xor y1 (w32-and (w32-shl y1 7) TMASKB)))
               (y3 (w32-xor y2 (w32-and (w32-shl y2 15) TMASKC)))
               (y4 (w32-xor y3 (w32-shr y3 18))))
          y4)))))

(define (seed! n) (init-by-array (k n)))

; getrandbits(32) -> w32 ; getrandbits-fix(k<=30) -> fixnum
(define (getrandbits32) (genrand))
(define (getrandbits-fix nb) (w32->fixnum (w32-shr (genrand) (- 32 nb))))

; ---------------------------------------------------------------------------
; number formatting.
; ---------------------------------------------------------------------------
(define HEXU "0123456789ABCDEF")
(define (nibU w sh) (string (string-ref HEXU (w32->fixnum (w32-and (w32-shr w sh) (k 15))))))
(define (x8-str w)
  (string-append "(X8 " (nibU w 28) " " (nibU w 24) " " (nibU w 20) " " (nibU w 16)
    " " (nibU w 12) " " (nibU w 8) " " (nibU w 4) " " (nibU w 0) ")"))
(define (n-form w)   ; little-endian nibble list
  (string-append "(N " (nibU w 0) " " (nibU w 4) " " (nibU w 8) " " (nibU w 12)
    " " (nibU w 16) " " (nibU w 20) " " (nibU w 24) " " (nibU w 28) ")"))
(define (pl s) (begin (display s) (newline)))

; ---------------------------------------------------------------------------
; arith fixtures.
; ---------------------------------------------------------------------------
(define (arith-loop n emit)
  (if (= n 0) #f
      (let ((a (getrandbits32)))
        (let ((b (getrandbits32)))
          (begin (emit a b) (arith-loop (- n 1) emit))))))
(define (gen-arith-qfasm)
  (begin (seed! 7)
    (arith-loop 40
      (lambda (a b)
        (begin
          (pl (string-append "(Add32 " (n-form a) " " (n-form b) ")"))
          (pl (string-append "(Sub32 " (n-form a) " " (n-form b) ")")))))))
(define (gen-arith-out)
  (begin (seed! 7)
    (arith-loop 40
      (lambda (a b)
        (begin (pl (n-form (w32-add a b))) (pl (n-form (w32-sub a b))))))))

; ---------------------------------------------------------------------------
; _randbelow / choice / sample / randrange (CPython algorithms).
; ---------------------------------------------------------------------------
(define (bitlen n) (if (= n 0) 0 (+ 1 (bitlen (quotient n 2)))))
(define (randbelow n)
  (let ((kb (bitlen n)))
    (rb-loop n kb)))
(define (rb-loop n kb)
  (let ((r (getrandbits-fix kb)))
    (if (< r n) r (rb-loop n kb))))
(define (choice lst) (list-ref lst (randbelow (length lst))))
(define (randrange-2 start stop) (+ start (randbelow (- stop start))))
(define (rfilter pred lst)
  (cond ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (rfilter pred (cdr lst))))
        (else (rfilter pred (cdr lst)))))
; sample(pop, 2) via CPython's pool algorithm -> (r1 . r2)
(define (sample2 pop)
  (let ((pool (list->vector pop)) (n (length pop)))
    (let ((j0 (randbelow n)))
      (let ((r1 (vector-ref pool j0)))
        (begin (vector-set! pool j0 (vector-ref pool (- n 1)))
          (let ((j1 (randbelow (- n 1))))
            (cons r1 (vector-ref pool j1))))))))

; ---------------------------------------------------------------------------
; Registers and byte helpers.
; ---------------------------------------------------------------------------
(define (rg name num) (cons name num))
(define (rn r) (cdr r))
(define (rnm r) (car r))
(define GP (list (rg "EAX" 0) (rg "ECX" 1) (rg "EDX" 2) (rg "EBX" 3) (rg "ESI" 6) (rg "EDI" 7)))
(define BASE00 GP)
(define BASE01 (list (rg "EAX" 0) (rg "ECX" 1) (rg "EDX" 2) (rg "EBX" 3) (rg "EBP" 5) (rg "ESI" 6) (rg "EDI" 7)))

(define HEXL "0123456789abcdef")
(define (hex2U n) (string-append (string (string-ref HEXU (quotient n 16))) (string (string-ref HEXU (remainder n 16)))))
(define (hex2L n) (string-append (string (string-ref HEXL (quotient n 16))) (string (string-ref HEXL (remainder n 16)))))
(define (le4 w)   ; list of 4 LE bytes (fixnums) of a w32
  (list (w32->fixnum (w32-and w (k 255)))
        (w32->fixnum (w32-and (w32-shr w 8) (k 255)))
        (w32->fixnum (w32-and (w32-shr w 16) (k 255)))
        (w32->fixnum (w32-and (w32-shr w 24) (k 255)))))
(define VBASEW (w32-hex 8 4 128 88))   ; 0x08048058

; ---------------------------------------------------------------------------
; Item model.  Each item is a tagged list; passes resolve labels + bytes.
;   (lbl key) (al4) (al8) (fix src size bytelist)
;   (rel8 src op key) (rel32 src prefix key adj) (abs32 src prefix key plus)
; ---------------------------------------------------------------------------
(define items-rev '())
(define (emit-item! it) (set! items-rev (cons it items-rev)))
(define (it-lbl key) (emit-item! (list 'lbl key)))
(define (it-al4) (emit-item! (list 'al4)))
(define (it-al8) (emit-item! (list 'al8)))
(define (it-fix src bl) (emit-item! (list 'fix src (length bl) bl)))
(define (it-rel8 src op key) (emit-item! (list 'rel8 src op key)))
(define (it-rel32 src prefix key adj) (emit-item! (list 'rel32 src prefix key adj)))
(define (it-abs32 src prefix key plus) (emit-item! (list 'abs32 src prefix key plus)))

(define (item-tag it) (car it))
(define (item-src it)   ; source sexp text
  (let ((tg (car it)))
    (cond ((eq? tg 'lbl) (string-append "(Label " (cadr it) ")"))
          ((eq? tg 'al4) "(Align4)")
          ((eq? tg 'al8) "(Align8)")
          (else (cadr it)))))
(define (item-size it pc)
  (let ((tg (car it)))
    (cond ((eq? tg 'lbl) 0)
          ((eq? tg 'al4) (remainder (- 4 (remainder pc 4)) 4))
          ((eq? tg 'al8) (remainder (- 8 (remainder pc 8)) 8))
          ((eq? tg 'fix) (caddr it))
          ((eq? tg 'rel8) 2)
          ((eq? tg 'rel32) (+ (length (caddr it)) 4))
          ((eq? tg 'abs32) (+ (length (caddr it)) 4)))))

; pass1: assoc list of (key . pc)
(define (pass1 items pc labels)
  (if (null? items) labels
      (let ((it (car items)))
        (if (eq? (item-tag it) 'lbl)
            (pass1 (cdr items) pc (cons (cons (cadr it) pc) labels))
            (pass1 (cdr items) (+ pc (item-size it pc)) labels)))))
(define (lookup key labels)
  (let ((p (assoc key labels))) (cdr p)))

; pass2: cons bytes onto bytes-rev
(define bytes-rev '())
(define (push-byte! b) (set! bytes-rev (cons b bytes-rev)))
(define (push-bytes! bl) (for-each push-byte! bl))
(define (zeros! n) (if (= n 0) #f (begin (push-byte! 0) (zeros! (- n 1)))))
(define (item-bytes! it pc labels)
  (let ((tg (car it)))
    (cond
      ((eq? tg 'lbl) #f)
      ((eq? tg 'al4) (zeros! (remainder (- 4 (remainder pc 4)) 4)))
      ((eq? tg 'al8) (zeros! (remainder (- 8 (remainder pc 8)) 8)))
      ((eq? tg 'fix) (push-bytes! (cadddr it)))
      ((eq? tg 'rel8)
       (begin (push-byte! (caddr it))
         (push-byte! (modulo (- (lookup (cadddr it) labels) (+ pc 2)) 256))))
      ((eq? tg 'rel32)
       (begin (push-bytes! (caddr it))
         (push-bytes! (le4 (k (- (lookup (cadddr it) labels) (+ pc (list-ref it 4))))))))
      ((eq? tg 'abs32)
       (begin (push-bytes! (caddr it))
         (push-bytes! (le4 (w32-add VBASEW (k (+ (list-ref it 4) (lookup (cadddr it) labels)))))))))))
(define (pass2 items pc labels)
  (if (null? items) #f
      (let ((it (car items)))
        (begin (item-bytes! it pc labels)
          (pass2 (cdr items) (+ pc (item-size it pc)) labels)))))

; ELF header bytes for entryoff=0, given code length and bss.
(define (elf-header codelen bss)
  (append
    (list 127 69 76 70 1 1 1 0 0 0 0 0 0 0 0 0
          2 0 3 0 1 0 0 0)
    (le4 VBASEW)                       ; e_entry = VBASE + 0
    (list 52 0 0 0 0 0 0 0 0 0 0 0
          52 0 32 0 1 0 0 0 0 0 0 0
          1 0 0 0 0 0 0 0 0 128 4 8 0 128 4 8)
    (le4 (k (+ 88 codelen)))           ; p_filesz
    (le4 (k (+ (+ 88 codelen) bss)))   ; p_memsz
    (list 7 0 0 0 0 16 0 0 0 0 0 0)))

; hexdump: 16 bytes/line, lowercase, space-separated, newline per line.
(define (hexdump-line bs) ; bs a list of up to 16 bytes
  (pl (hd-join bs)))
(define (hd-join bs)
  (if (null? bs) ""
      (if (null? (cdr bs)) (hex2L (car bs))
          (string-append (hex2L (car bs)) " " (hd-join (cdr bs))))))
(define (hexdump bs)
  (if (null? bs) #f
      (begin (hexdump-line (take16 bs)) (hexdump (drop16 bs)))))
(define (take16 bs) (tk bs 16))
(define (drop16 bs) (dp bs 16))
(define (tk l n) (if (or (= n 0) (null? l)) '() (cons (car l) (tk (cdr l) (- n 1)))))
(define (dp l n) (if (or (= n 0) (null? l)) l (dp (cdr l) (- n 1))))

; Emit the qfasm source for the current items list, given bss w32.
(define (emit-src items bssw)
  (begin
    (pl (string-append "(Assemble (Program Entry " (x8-str bssw)))
    (for-each (lambda (it) (pl (string-append "  (Ins " (item-src it)))) items)
    (pl (string-append "  End" (repeat-str ")" (length items)) "))"))))
(define (repeat-str s n) (if (= n 0) "" (string-append s (repeat-str s (- n 1)))))

; ---------------------------------------------------------------------------
; exit42 fixture.
; ---------------------------------------------------------------------------
(define (build-exit42)
  (begin
    (set! items-rev '())
    (it-lbl "Entry")
    (it-fix "(MovRI EAX (X8 0 0 0 0 0 0 0 1))" (list 184 1 0 0 0))
    (it-rel8 "(JmpS Skip)" 235 "Skip")
    (it-fix "(Db DE)" (list 222))
    (it-lbl "Skip")
    (it-fix "(MovRI EBX (X8 0 0 0 0 0 0 2 A))" (list 187 42 0 0 0))
    (it-fix "(Int 80)" (list 205 128))
    (reverse items-rev)))
(define (run-model items bss)   ; -> full binary byte list (header ++ code)
  (let ((labels (pass1 items 0 '())))
    (begin
      (set! bytes-rev '())
      (pass2 items 0 labels)
      (let ((code (reverse bytes-rev)))
        (append (elf-header (length code) bss) code)))))

; ---------------------------------------------------------------------------
; big fixture.
; ---------------------------------------------------------------------------
(define OP8 (list (rg "AddI8" 0) (rg "OrI8" 1) (rg "AndI8" 4) (rg "SubI8" 5) (rg "XorI8" 6) (rg "CmpI8" 7)))
(define SHs (list (rg "ShlI8" 4) (rg "ShrI8" 5) (rg "SarI8" 7)))
(define UNs (list (rg "NotR" 2) (rg "NegR" 3)))
(define RRs (list (rg "AddRR" 1) (rg "SubRR" 41) (rg "CmpRR" 57) (rg "XorRR" 49) (rg "OrRR" 9) (rg "AndRR" 33) (rg "TestRR" 133)))
(define I32s (list (rg "AddI32" 0) (rg "AndI32" 4) (rg "SubI32" 5) (rg "CmpI32" 7)))
(define SJs (list (rg "Jz" 116) (rg "Jnz" 117) (rg "Jb" 114) (rg "Jae" 115) (rg "Jbe" 118) (rg "Ja" 119) (rg "Js" 120) (rg "Jns" 121) (rg "Jl" 124) (rg "Jge" 125) (rg "Jle" 126) (rg "Jg" 127) (rg "JmpS" 235)))
(define CCs (list (rg "Jz32" 132) (rg "Jnz32" 133) (rg "Jb32" 130) (rg "Jae32" 131) (rg "Jbe32" 134) (rg "Ja32" 135) (rg "Jl32" 140) (rg "Jge32" 141) (rg "Jle32" 142) (rg "Jg32" 143)))

(define (bkey n) (string-append "(B " (number->string n) ")"))
(define (dkey n) (string-append "(D " (number->string n) ")"))

(define (big-block k)
  (let* ((s2 (sample2 GP)) (r1 (car s2)) (r2 (cdr s2))
         (imm (getrandbits32)))
    (begin
      (it-lbl (bkey k))
      (it-fix (string-append "(MovRI " (rnm r1) " " (x8-str imm) ")") (cons (+ 184 (rn r1)) (le4 imm)))
      (it-fix (string-append "(MovRR " (rnm r2) " " (rnm r1) ")") (list 137 (+ 192 (* 8 (rn r1)) (rn r2))))
      (let ((op8 (choice OP8)) (b8 (randbelow 256)))
        (it-fix (string-append "(" (rnm op8) " " (rnm r1) " " (hex2U b8) ")") (list 131 (+ 192 (* 8 (rn op8)) (rn r1)) b8)))
      (let ((sh (choice SHs)) (shn (randrange-2 1 31)))
        (it-fix (string-append "(" (rnm sh) " " (rnm r2) " " (hex2U shn) ")") (list 193 (+ 192 (* 8 (rn sh)) (rn r2)) shn)))
      (let ((un (choice UNs)))
        (it-fix (string-append "(" (rnm un) " " (rnm r1) ")") (list 247 (+ 192 (* 8 (rn un)) (rn r1)))))
      (let ((rr (choice RRs)))
        (it-fix (string-append "(" (rnm rr) " " (rnm r1) " " (rnm r2) ")") (list (rn rr) (+ 192 (* 8 (rn r2)) (rn r1)))))
      (let ((i32 (choice I32s)) (v32 (getrandbits32)))
        (it-fix (string-append "(" (rnm i32) " " (rnm r2) " " (x8-str v32) ")") (cons 129 (cons (+ 192 (* 8 (rn i32)) (rn r2)) (le4 v32)))))
      (it-fix (string-append "(PushR " (rnm r1) ")") (list (+ 80 (rn r1))))
      (it-fix (string-append "(PopR " (rnm r1) ")") (list (+ 88 (rn r1))))
      (it-fix (string-append "(IncR " (rnm r2) ")") (list (+ 64 (rn r2))))
      (it-fix (string-append "(DecR " (rnm r2) ")") (list (+ 72 (rn r2))))
      (let* ((b0 (choice BASE00)) (b1 (choice BASE01)) (d8 (randbelow 128))
             (rm (choice (rfilter (lambda (r) (not (string=? (rnm r) (rnm b0)))) GP))))
        (begin
          (it-fix (string-append "(MovRM " (rnm rm) " " (rnm b0) ")") (list 139 (+ (* 8 (rn rm)) (rn b0))))
          (it-fix (string-append "(MovMR " (rnm b0) " " (rnm rm) ")") (list 137 (+ (* 8 (rn rm)) (rn b0))))
          (it-fix (string-append "(MovRMD " (rnm rm) " " (rnm b1) " " (hex2U d8) ")") (list 139 (+ 64 (* 8 (rn rm)) (rn b1)) d8))
          (it-fix (string-append "(MovMDR " (rnm b1) " " (hex2U d8) " " (rnm rm) ")") (list 137 (+ 64 (* 8 (rn rm)) (rn b1)) d8))
          (it-fix (string-append "(MovzxRMb " (rnm rm) " " (rnm b0) ")") (list 15 182 (+ (* 8 (rn rm)) (rn b0))))
          (it-fix (string-append "(MovbMR " (rnm b0) " " (rnm rm) ")") (list 136 (+ (* 8 (rn rm)) (rn b0))))
          (it-fix (string-append "(LeaRMD " (rnm rm) " " (rnm b1) " " (hex2U d8) ")") (list 141 (+ 64 (* 8 (rn rm)) (rn b1)) d8))
          (let ((dl (dkey (randbelow 80))))
            (begin
              (it-abs32 (string-append "(MovRMemL " (rnm rm) " " dl ")") (list 139 (+ (* 8 (rn rm)) 5)) dl 0)
              (it-abs32 (string-append "(MovRILabel " (rnm rm) " " dl ")") (list (+ 184 (rn rm))) dl 0)
              (it-abs32 (string-append "(MovRIConst " (rnm rm) " " dl ")") (list (+ 184 (rn rm))) dl 1)
              (it-abs32 (string-append "(CmpEaxLabel " dl ")") (list 61) dl 0)))
          (let ((sj (choice SJs)) (lbl (string-append "(S " (number->string k) ")")))
            (begin
              (it-rel8 (string-append "(" (rnm sj) " " lbl ")") (rn sj) lbl)
              (it-fix "(Db DE)" (list 222))
              (it-lbl lbl)))
          (let ((tb (bkey (randbelow 80))) (cc (choice CCs)) (lbl2 (string-append "(T " (number->string k) ")")))
            (begin
              (it-rel8 (string-append "(JmpS " lbl2 ")") 235 lbl2)
              (it-rel32 (string-append "(" (rnm cc) " " tb ")") (list 15 (rn cc)) tb 6)
              (it-rel32 (string-append "(Call (Fn " (number->string (remainder k 7)) "))") (list 232) (string-append "(Fn " (number->string (remainder k 7)) ")") 5)
              (it-lbl lbl2)))
          (if (= (remainder k 3) 0) (it-al4) #f)
          (if (= (remainder k 7) 0) (it-al8) #f))))))

(define (big-blocks k) (if (= k 80) #f (begin (big-block k) (big-blocks (+ k 1)))))
(define (big-fns f) (if (= f 7) #f (begin (it-lbl (string-append "(Fn " (number->string f) ")")) (it-fix "(Nop)" (list 144)) (it-fix "(Ret)" (list 195)) (big-fns (+ f 1)))))
(define (big-data k)
  (if (= k 80) #f
      (begin
        (it-lbl (dkey k))
        (let ((v (getrandbits32)))
          (it-fix (string-append "(Dd " (x8-str v) ")") (le4 v)))
        (it-abs32 (string-append "(DLabel " (bkey k) ")") '() (bkey k) 0)
        (it-abs32 (string-append "(DConst " (bkey k) ")") '() (bkey k) 1)
        (it-fix "(DNil)" (list 1 0 0 0))
        (big-data (+ k 1)))))

(define (build-big)
  (begin
    (set! items-rev '())
    (seed! 42)
    (big-blocks 0)
    (it-rel32 "(Jmp32 Done)" (list 233) "Done" 5)
    (big-fns 0)
    (it-al4)
    (big-data 0)
    (it-lbl "Done")
    (it-fix (string-append "(MovRI EAX " (x8-str (k 1)) ")") (list 184 1 0 0 0))
    (it-fix (string-append "(MovRI EBX " (x8-str (k 42)) ")") (list 187 42 0 0 0))
    (it-fix "(Int 80)" (list 205 128))
    ; items.insert(0, Entry label); items.insert(1, Jmp32 Done)
    (let ((mainlist (reverse items-rev)))
      (cons (list 'lbl "Entry")
        (cons (list 'rel32 "(Jmp32 Done)" (list 233) "Done" 5) mainlist)))))

; ---------------------------------------------------------------------------
; dispatch.
; ---------------------------------------------------------------------------
(define (arg1)
  (let ((a (command-line))) (if (and (pair? a) (pair? (cdr a))) (cadr a) #f)))

(define (main)
  (let ((a (arg1)))
    (cond
      ((equal? a "arith-qfasm") (gen-arith-qfasm))
      ((equal? a "arith-out") (gen-arith-out))
      ((equal? a "exit42-qfasm") (emit-src (build-exit42) (k 0)))
      ((equal? a "exit42-hex") (hexdump (run-model (build-exit42) 0)))
      ((equal? a "exit42-status") (pl "42"))
      ((equal? a "big-qfasm") (emit-src (build-big) (k 1048576)))
      ((equal? a "big-hex") (hexdump (run-model (build-big) 1048576)))
      ((equal? a "big-status") (pl "42"))
      (else (pl "usage")))))
(main)
