(define baseline (%gc-live-units))
(define held (make-string 16384 #\x))
(define retained (%gc-live-units))
(write (>= (- retained baseline) 2048)) (newline)
(write (char=? (string-ref held 16383) #\x)) (newline)
(set! held #f)
; A string primitive can leave its last raw buffer pointer in a register.
; Replace that conservative root before asserting reclamation of the big one.
(string-ref (make-string 1 #\y) 0)
(gc)
(define released (%gc-live-units))
(write (< released (+ baseline 128))) (newline)
(define largest (%gc-largest-free-units))
(write (and (>= largest 2048) (<= largest 8192))) (newline)
