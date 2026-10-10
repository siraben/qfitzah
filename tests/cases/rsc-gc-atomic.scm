; White-box collector test: byte contents resembling an allocated address are
; data, not edges. %identity-hash rounds a pointer down to a 16-byte boundary,
; which lies in the same allocation (payloads follow an eight-byte header).
(define baseline (%gc-live-units))
(define anchor (vector (make-string 16384 #\x)))
(define bytes (make-string 4 #\nul))
(define address (* 16 (%identity-hash anchor)))
(define (encode i n)
  (if (= i 4) #t
      (begin (string-set! bytes i (integer->char (remainder n 256)))
             (encode (+ i 1) (quotient n 256)))))
(encode 0 address)
(define saved (%gc-live-units))
(set! anchor #f)
(set! address #f)
; Replace incidental raw scratch-register roots, but keep the four bytes live.
(string-ref (make-string 1 #\y) 0)
(%memq #f '())
(gc)
(write (< (%gc-live-units) (+ baseline 128))) (newline)
(write (= (string-length bytes) 4)) (newline)
