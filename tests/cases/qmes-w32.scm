; P1 Part A: differential battery for the 32-bit word (w32) primitives.
; Expected answers in qmes-w32.expected are computed independently (by hand)
; and cover wraparound past 2^31, signed vs unsigned compare, idiv sign,
; bit ops, shr-vs-sar, values built past 2^30 (via w32-mul / w32-shl), and
; the raw vector-word accessors.

; --- small arithmetic ------------------------------------------------------
(display (w32->fixnum (w32-add (w32-from-fixnum 5) (w32-from-fixnum 3)))) (newline)
(display (w32->fixnum (w32-sub (w32-from-fixnum 5) (w32-from-fixnum 3)))) (newline)
(display (w32->fixnum (w32-mul (w32-from-fixnum 5) (w32-from-fixnum 3)))) (newline)

; --- predicate -------------------------------------------------------------
(display (w32? (w32-from-fixnum 5))) (newline)
(display (w32? 5)) (newline)
(display (w32? '(1 2))) (newline)

; --- bitwise (results fit in 30 bits) --------------------------------------
(display (w32->fixnum (w32-and (w32-from-fixnum 61680) (w32-from-fixnum 4080)))) (newline)
(display (w32->fixnum (w32-or  (w32-from-fixnum 61680) (w32-from-fixnum 4080)))) (newline)
(display (w32->fixnum (w32-xor (w32-from-fixnum 61680) (w32-from-fixnum 4080)))) (newline)
; w32-not a == a xor 0xFFFFFFFF
(display (w32-eq? (w32-not (w32-from-fixnum 61680))
                  (w32-xor (w32-from-fixnum 61680) (w32-from-fixnum -1)))) (newline)

; --- shifts ----------------------------------------------------------------
(display (w32->fixnum (w32-shl (w32-from-fixnum 3) 4))) (newline)
(display (w32->fixnum (w32-shr (w32-from-fixnum 256) 2))) (newline)
(display (w32->fixnum (w32-sar (w32-from-fixnum -256) 2))) (newline)
; shr is logical, sar is arithmetic: distinguish on 0xFFFFFFFF
(display (w32->fixnum (w32-shr (w32-from-fixnum -1) 28))) (newline)
(display (w32->fixnum (w32-sar (w32-from-fixnum -1) 28))) (newline)

; --- signed division (idiv truncates toward zero) --------------------------
(display (w32->fixnum (w32-quot (w32-from-fixnum -7) (w32-from-fixnum 2)))) (newline)
(display (w32->fixnum (w32-rem  (w32-from-fixnum -7) (w32-from-fixnum 2)))) (newline)
(display (w32->fixnum (w32-quot (w32-from-fixnum 17) (w32-from-fixnum 5)))) (newline)
(display (w32->fixnum (w32-rem  (w32-from-fixnum 17) (w32-from-fixnum 5)))) (newline)

; --- large values > 2^30 (built via w32-shl and w32-mul) -------------------
(define big  (w32-shl (w32-from-fixnum 1) 31))                        ; 0x80000000
(define bigm (w32-mul (w32-from-fixnum 65536) (w32-from-fixnum 32768))) ; 2^31
(display (w32-eq? big bigm)) (newline)

; --- wraparound past 2^31 --------------------------------------------------
(display (w32->fixnum (w32-add big big))) (newline)
(display (w32-eq? (w32-add big big) (w32-from-fixnum 0))) (newline)

; --- signed vs unsigned compare on big (-2^31 signed, 2^31 unsigned) -------
(display (w32-lt?  big (w32-from-fixnum 0))) (newline)
(display (w32-ult? big (w32-from-fixnum 0))) (newline)
(display (w32-ult? (w32-from-fixnum 0) big)) (newline)

; --- signed vs unsigned divide differ on big -------------------------------
(display (w32-eq? (w32-uquot big (w32-from-fixnum 2)) (w32-shl (w32-from-fixnum 1) 30))) (newline)
(display (w32-eq? (w32-quot big (w32-from-fixnum 2))
                  (w32-sub (w32-from-fixnum 0) (w32-shl (w32-from-fixnum 1) 30)))) (newline)
(display (w32->fixnum (w32-urem  (w32-from-fixnum 100) (w32-from-fixnum 7)))) (newline)
(display (w32->fixnum (w32-uquot (w32-from-fixnum 100) (w32-from-fixnum 7)))) (newline)

; --- raw vector-word round trip with a value > 2^30 ------------------------
(define v (make-vector 4 0))
(vec-raw-set! v 2 big)
(display (w32-eq? (vec-raw-ref v 2) big)) (newline)  ; raw word survives
(display (w32? (vector-ref v 2))) (newline)          ; raw != tagged: not a w32 box
(display (eq? (vector-ref v 2) big)) (newline)       ; raw path distinct from boxed
