; ===========================================================================
; qmes-w64.scm — the 64-bit number substrate override (x86_64 variant).
;
; Cat'd AFTER qmes.scm and BEFORE qmes-main.scm; rsc's last-define-wins GV
; semantics make every redefinition here shadow the 32-bit original at every
; call site.  A TNUMBER becomes  [TNUMBER | hi | lo]  in the existing 3-word
; cell (hi in the car word, which was 0 for the 32-bit build).  GC, cell
; stride, and the arena are untouched (hi/lo are raw words like the old value).
;
; The w64 op layer is PURE SCHEME over the existing w32 primitives; a 64-bit
; value in flight is carried as two separate w32 boxes (hi lo), and helpers
; that must yield both words return a host pair  (cons hi lo).  Target
; semantics = amd64 C `long` as M2-Planet compiles src/math.c: wrap mod 2^64,
; arithmetic right shift for signed, shift counts masked & 63.
; ===========================================================================

; --- w32 constants ---------------------------------------------------------
(define w64-k0 (w32-from-fixnum 0))
(define w64-k1 (w32-from-fixnum 1))
(define w64-k10 (w32-from-fixnum 10))
(define w64-kFFFF (w32-from-fixnum 65535))
(define w64-wm1 (w32-not w64-k0))            ; 0xFFFFFFFF
(define w64-k65536 (w32-shl w64-k1 16))      ; 2^16
(define (w32-signhi w) (w32-sar w 31))       ; sign word of a single w32

; --- representation: [TNUMBER | hi | lo] -----------------------------------
(define (make-number-2w hi lo)
  (let ((i (alloc-n 1)))
    (raw-set! i 0 (w32-from-fixnum TNUMBER))
    (raw-set! i 1 hi)
    (raw-set! i 2 lo)
    i))
(define (make-number-p p) (make-number-2w (car p) (cdr p)))
(define (num-hi i) (raw-ref i 1))
; OVERRIDE make-number-w: sign-extend a single-word value into 64 bits so that
; every legacy single-word call site (string-length, char->integer, indices,
; folded negatives, …) stays correct without editing it.  make-number-fx and
; make-number-w-callers thus inherit correct hi words.
(define (make-number-w w) (make-number-2w (w32-signhi w) w))

; --- core w64 ops (return host pairs (hi . lo)) -----------------------------
(define (w64+ ahi alo bhi blo)
  (let ((lo (w32-add alo blo)))
    (cons (w32-add (w32-add ahi bhi) (if (w32-ult? lo alo) w64-k1 w64-k0)) lo)))
(define (w64- ahi alo bhi blo)
  (let ((lo (w32-sub alo blo)))
    (cons (w32-sub (w32-sub ahi bhi) (if (w32-ult? alo blo) w64-k1 w64-k0)) lo)))
(define (w64-neg-p hi lo) (w64- w64-k0 w64-k0 hi lo))

; full 32x32 -> 64 unsigned product (Hacker's Delight fig 8-1); every 16x16
; partial product fits in a w32 so w32-mul (low 32) is exact for them.
(define (mul32 u v)
  (let* ((u0 (w32-and u w64-kFFFF)) (u1 (w32-shr u 16))
         (v0 (w32-and v w64-kFFFF)) (v1 (w32-shr v 16))
         (t0 (w32-mul u0 v0))
         (w0 (w32-and t0 w64-kFFFF))
         (kk (w32-shr t0 16))
         (t1 (w32-add (w32-mul u1 v0) kk))
         (w1 (w32-and t1 w64-kFFFF))
         (w2 (w32-shr t1 16))
         (t2 (w32-add (w32-mul u0 v1) w1))
         (k2 (w32-shr t2 16))
         (lo (w32-add (w32-shl t2 16) w0))
         (hi (w32-add (w32-add (w32-mul u1 v1) w2) k2)))
    (cons hi lo)))
; (a hi:lo) * (b hi:lo) mod 2^64
(define (w64-mul-p ahi alo bhi blo)
  (let ((ll (mul32 alo blo))
        (cross (w32-add (w32-mul alo bhi) (w32-mul ahi blo))))
    (cons (w32-add (car ll) cross) (cdr ll))))

; --- shifts (c a fixnum >= 0; masked & 63 like amd64) -----------------------
(define (w64-shl-p hi lo c0)
  (let ((c (remainder c0 64)))
    (cond ((= c 0) (cons hi lo))
          ((< c 32) (cons (w32-or (w32-shl hi c) (w32-shr lo (- 32 c)))
                          (w32-shl lo c)))
          ((= c 32) (cons lo w64-k0))
          (else (cons (w32-shl lo (- c 32)) w64-k0)))))
(define (w64-sar-p hi lo c0)                 ; arithmetic right shift
  (let ((c (remainder c0 64)))
    (cond ((= c 0) (cons hi lo))
          ((< c 32) (cons (w32-sar hi c)
                          (w32-or (w32-shr lo c) (w32-shl hi (- 32 c)))))
          ((= c 32) (cons (w32-sar hi 31) hi))
          (else (cons (w32-sar hi 31) (w32-sar hi (- c 32)))))))

; --- comparisons / predicates ----------------------------------------------
(define (w64-eq? ahi alo bhi blo) (and (w32-eq? ahi bhi) (w32-eq? alo blo)))
(define (w64-ult? ahi alo bhi blo)           ; unsigned <
  (cond ((w32-ult? ahi bhi) #t)
        ((w32-eq? ahi bhi) (w32-ult? alo blo))
        (else #f)))
(define (w64-slt? ahi alo bhi blo)           ; signed <
  (cond ((w32-lt? ahi bhi) #t)
        ((w32-eq? ahi bhi) (w32-ult? alo blo))
        (else #f)))
(define (w64-zero? hi lo) (and (w32-eq? hi w64-k0) (w32-eq? lo w64-k0)))

; --- unsigned divmod -> (cons (qhi . qlo) (rhi . rlo)) ----------------------
; case (a) small divisor d (0 < d < 2^16): long division over 4 16-bit limbs.
(define (udm-small nhi nlo d)
  (let ((h1 (w32-shr nhi 16)) (h0 (w32-and nhi w64-kFFFF))
        (l1 (w32-shr nlo 16)) (l0 (w32-and nlo w64-kFFFF)))
    (let* ((a3 (w32-uquot h1 d))   (r3 (w32-urem h1 d))
           (c2 (w32-add (w32-shl r3 16) h0))
           (a2 (w32-uquot c2 d))   (r2 (w32-urem c2 d))
           (c1 (w32-add (w32-shl r2 16) l1))
           (a1 (w32-uquot c1 d))   (r1 (w32-urem c1 d))
           (c0 (w32-add (w32-shl r1 16) l0))
           (a0 (w32-uquot c0 d))   (r0 (w32-urem c0 d)))
      (cons (cons (w32-or (w32-shl a3 16) a2) (w32-or (w32-shl a1 16) a0))
            (cons w64-k0 r0)))))
; case (c) general: shift-subtract, 64 iterations, bit index i = 63..0.
(define (nbit nhi nlo i)
  (if (>= i 32) (w32-and (w32-shr nhi (- i 32)) w64-k1)
      (w32-and (w32-shr nlo i) w64-k1)))
(define (qsetbit qhi qlo i)
  (if (>= i 32) (cons (w32-or qhi (w32-shl w64-k1 (- i 32))) qlo)
      (cons qhi (w32-or qlo (w32-shl w64-k1 i)))))
(define (udm-gen nhi nlo dhi dlo qhi qlo rhi rlo i)
  (if (< i 0) (cons (cons qhi qlo) (cons rhi rlo))
      (let ((rsh (w64-shl-p rhi rlo 1)))
        (let ((r2hi (car rsh)) (r2lo (w32-or (cdr rsh) (nbit nhi nlo i))))
          (if (w64-ult? r2hi r2lo dhi dlo)
              (udm-gen nhi nlo dhi dlo qhi qlo r2hi r2lo (- i 1))
              (let ((rs (w64- r2hi r2lo dhi dlo))
                    (qs (qsetbit qhi qlo i)))
                (udm-gen nhi nlo dhi dlo (car qs) (cdr qs)
                         (car rs) (cdr rs) (- i 1))))))))
(define (w64-udivmod nhi nlo dhi dlo)
  (cond ((and (w32-eq? dhi w64-k0) (w32-ult? dlo w64-k65536))
         (udm-small nhi nlo dlo))                          ; (a) 0<d<2^16
        ((and (w32-eq? dhi w64-k1) (w32-eq? dlo w64-k0))
         (cons (cons w64-k0 nhi) (cons w64-k0 nlo)))       ; (b) d = 2^32
        (else (udm-gen nhi nlo dhi dlo w64-k0 w64-k0 w64-k0 w64-k0 63))))
(define (w64-uquot nhi nlo dhi dlo) (car (w64-udivmod nhi nlo dhi dlo)))
(define (w64-urem  nhi nlo dhi dlo) (cdr (w64-udivmod nhi nlo dhi dlo)))

; ===========================================================================
; The 13 math.c builtins, widened (mirrors the 32-bit transliteration).
; ===========================================================================
(define (b-plus x) (plus-loop x w64-k0 w64-k0))
(define (plus-loop x ahi alo)
  (if (= x cell-nil) (make-number-2w ahi alo)
      (let ((c (cell-car x)))
        (let ((s (w64+ ahi alo (num-hi c) (num-value c))))
          (plus-loop (cell-cdr x) (car s) (cdr s))))))
(define (b-minus x)
  (let ((c (cell-car x)))
    (let ((rest (cell-cdr x)) (ahi (num-hi c)) (alo (num-value c)))
      (if (= rest cell-nil)
          (make-number-p (w64-neg-p ahi alo))
          (minus-loop rest ahi alo)))))
(define (minus-loop x ahi alo)
  (if (= x cell-nil) (make-number-2w ahi alo)
      (let ((c (cell-car x)))
        (let ((s (w64- ahi alo (num-hi c) (num-value c))))
          (minus-loop (cell-cdr x) (car s) (cdr s))))))
(define (b-mult x) (mult-loop x w64-k0 w64-k1))
(define (mult-loop x ahi alo)
  (if (= x cell-nil) (make-number-2w ahi alo)
      (let ((c (cell-car x)))
        (let ((p (w64-mul-p ahi alo (num-hi c) (num-value c))))
          (mult-loop (cell-cdr x) (car p) (cdr p))))))
(define (b-is x)
  (if (= x cell-nil) cell-t
      (is-loop (cell-cdr x) (num-hi (cell-car x)) (num-value (cell-car x)))))
(define (is-loop x nhi nlo)
  (cond ((= x cell-nil) cell-t)
        ((w64-eq? (num-hi (cell-car x)) (num-value (cell-car x)) nhi nlo)
         (is-loop (cell-cdr x) nhi nlo))
        (else cell-f)))
; (> a b …): C returns cell_f as soon as v >= n; i.e. keep going while v < n.
(define (b-greater x)
  (if (= x cell-nil) cell-t
      (greater-loop (cell-cdr x) (num-hi (cell-car x)) (num-value (cell-car x)))))
(define (greater-loop x nhi nlo)
  (cond ((= x cell-nil) cell-t)
        (else (let ((c (cell-car x)))
                (let ((vhi (num-hi c)) (vlo (num-value c)))
                  (if (w64-slt? vhi vlo nhi nlo)
                      (greater-loop (cell-cdr x) vhi vlo) cell-f))))))
; (< a b …): C returns cell_f as soon as v <= n; keep going while n < v.
(define (b-less x)
  (if (= x cell-nil) cell-t
      (less-loop (cell-cdr x) (num-hi (cell-car x)) (num-value (cell-car x)))))
(define (less-loop x nhi nlo)
  (cond ((= x cell-nil) cell-t)
        (else (let ((c (cell-car x)))
                (let ((vhi (num-hi c)) (vlo (num-value c)))
                  (if (w64-slt? nhi nlo vhi vlo)
                      (less-loop (cell-cdr x) vhi vlo) cell-f))))))
(define (b-logand x) (logand-loop x w64-wm1 w64-wm1))
(define (logand-loop x ahi alo)
  (if (= x cell-nil) (make-number-2w ahi alo)
      (let ((c (cell-car x)))
        (logand-loop (cell-cdr x)
                     (w32-and ahi (num-hi c)) (w32-and alo (num-value c))))))
(define (b-logior x) (logior-loop x w64-k0 w64-k0))
(define (logior-loop x ahi alo)
  (if (= x cell-nil) (make-number-2w ahi alo)
      (let ((c (cell-car x)))
        (logior-loop (cell-cdr x)
                     (w32-or ahi (num-hi c)) (w32-or alo (num-value c))))))
(define (b-logxor x) (logxor-loop x w64-k0 w64-k0))
(define (logxor-loop x ahi alo)
  (if (= x cell-nil) (make-number-2w ahi alo)
      (let ((c (cell-car x)))
        (logxor-loop (cell-cdr x)
                     (w32-xor ahi (num-hi c)) (w32-xor alo (num-value c))))))
(define (b-lognot x)
  (let ((c (cell-car x)))
    (make-number-2w (w32-not (num-hi c)) (w32-not (num-value c)))))
; ash: count>=0 -> n << count ; count<0 -> n >> -count (arithmetic).
(define (b-ash a b)
  (let ((nhi (num-hi a)) (nlo (num-value a)) (c (w32->fixnum (num-value b))))
    (if (>= c 0)
        (make-number-p (w64-shl-p nhi nlo (remainder c 64)))
        (make-number-p (w64-sar-p nhi nlo (remainder (- 0 c) 64))))))
; modulo (math.c:190): w=|v|; while(n<0) n+=w; u=(n?n%w:0); if v<0 negate.
(define (b-modulo a b)
  (let ((nhi (num-hi a)) (nlo (num-value a)) (vhi (num-hi b)) (vlo (num-value b)))
    (if (w64-zero? vhi vlo) (qerror-type b)      ; guard modulo-by-zero (see qmes.scm)
    (let ((sign-p (w32-lt? vhi w64-k0)))
      (let ((w (if sign-p (w64-neg-p vhi vlo) (cons vhi vlo))))
        (let ((whi (car w)) (wlo (cdr w)))
          (let ((n2 (mod-raise nhi nlo whi wlo)))
            (let ((u (if (w64-zero? (car n2) (cdr n2)) (cons w64-k0 w64-k0)
                         (w64-urem (car n2) (cdr n2) whi wlo))))
              (if sign-p (make-number-p (w64-neg-p (car u) (cdr u)))
                  (make-number-2w (car u) (cdr u)))))))))))
(define (mod-raise nhi nlo whi wlo)
  (if (w32-lt? nhi w64-k0)
      (let ((s (w64+ nhi nlo whi wlo))) (mod-raise (car s) (cdr s) whi wlo))
      (cons nhi nlo)))
; divide (math.c:147, as M2-Planet actually compiles it): u = |first arg|;
; then for each divisor v, u = u / (size_t)v  (v used RAW as unsigned, so a
; negative divisor is a huge unsigned => quotient 0).  The source's final
; `if (sign_p) n = -n` never fires: M2-Planet miscompiles divide's
; `sign_p = sign_p && v>0 || !sign_p && v<0` to always-0, so the result is the
; unsigned magnitude quotient, never negated.  This is the amd64 reference
; truth (differentially confirmed vs bin/mes-m2-64).  The i386 corpus never
; divides a negative, which is why the 32-bit transliteration went untested.
(define (b-div x)
  (if (= x cell-nil) (make-number-fx 1)
      (let ((c (cell-car x)))
        (let ((n0hi (num-hi c)) (n0lo (num-value c)))
          (let ((u (if (w32-lt? n0hi w64-k0) (w64-neg-p n0hi n0lo) (cons n0hi n0lo))))
            (b-div-loop (cell-cdr x) (car u) (cdr u)))))))
(define (b-div-loop x uhi ulo)
  (if (= x cell-nil) (make-number-2w uhi ulo)
      (let ((c (cell-car x)))
        (let ((vhi (num-hi c)) (vlo (num-value c)))
          (cond ((w64-zero? vhi vlo) (qerror-type c))
                ((w64-zero? uhi ulo) (make-number-2w uhi ulo))
                ((w64-eq? vhi vlo w64-k0 w64-k1) (b-div-loop (cell-cdr x) uhi ulo))
                (else (let ((q (w64-uquot uhi ulo vhi vlo)))
                        (b-div-loop (cell-cdr x) (car q) (cdr q)))))))))

; ===========================================================================
; Reader: decimal parse-number and #x/#b/#o radix reader, widened to 2^64.
; ===========================================================================
(define (parse-number start len)
  (let ((c0 (char->integer (string-ref g-bytes start))))
    (cond ((= c0 45)
           (let ((p (parse-digits64 (+ start 1) (- len 1) w64-k0 w64-k0)))
             (make-number-p (w64-neg-p (car p) (cdr p)))))
          ((= c0 43)
           (make-number-p (parse-digits64 (+ start 1) (- len 1) w64-k0 w64-k0)))
          (else (make-number-p (parse-digits64 start len w64-k0 w64-k0))))))
(define (parse-digits64 start len ahi alo)
  (if (= len 0) (cons ahi alo)
      (let ((d (- (char->integer (string-ref g-bytes start)) 48)))
        (let ((m (w64-mul-p ahi alo w64-k0 w64-k10)))
          (let ((s (w64+ (car m) (cdr m) w64-k0 (w32-from-fixnum d))))
            (parse-digits64 (+ start 1) (- len 1) (car s) (cdr s)))))))
(define (radix-loop64 radix shift ahi alo)
  (let ((d (radix-digit (peekchar) radix)))
    (if (< d 0) (cons ahi alo)
        (begin (getchar-)
               (let ((s (w64-shl-p ahi alo shift)))
                 (let ((a (w64+ (car s) (cdr s) w64-k0 (w32-from-fixnum d))))
                   (radix-loop64 radix shift (car a) (cdr a))))))))
(define (reader-read-radix radix shift)
  (let ((neg (if (= (peekchar) 45) (begin (getchar-) 1) 0)))
    (let ((p (radix-loop64 radix shift w64-k0 w64-k0)))
      (if (= neg 1) (make-number-p (w64-neg-p (car p) (cdr p)))
          (make-number-2w (car p) (cdr p))))))

; ===========================================================================
; Printer, value-equality and value-copy seams, widened to two words.
; ===========================================================================
(define (emit-tnumber fd x)
  (let ((hi (num-hi x)) (lo (num-value x)))
    (if (w32-lt? hi w64-k0)
        (begin (emit fd 45)
               (let ((n (w64-neg-p hi lo))) (emit-udigits fd (car n) (cdr n))))
        (emit-udigits fd hi lo))))
(define (emit-udigits fd hi lo)              ; unsigned 64-bit decimal
  (let ((dm (w64-udivmod hi lo w64-k0 w64-k10)))
    (let ((q (car dm)) (r (cdr dm)))
      (if (w64-zero? (car q) (cdr q))
          (emit fd (+ 48 (w32->fixnum (cdr r))))
          (begin (emit-udigits fd (car q) (cdr q))
                 (emit fd (+ 48 (w32->fixnum (cdr r)))))))))
(define (num=? a b)
  (w64-eq? (num-hi a) (num-value a) (num-hi b) (num-value b)))
(define (copy-num e) (make-number-2w (num-hi e) (num-value e)))
