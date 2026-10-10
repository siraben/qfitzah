; Retain 160 MiB, beyond the former host's entire 128 MiB heap. Explicit GC
; also touches owner/work metadata beyond the former fixed 256 MiB ELF BSS.
(define chunk-size 4194304)
(define (chunks n)
  (if (= n 0) '()
      (cons (make-string chunk-size (integer->char (+ 32 n))) (chunks (- n 1)))))
(define (check-chunks xs n)
  (if (= n 0)
      (if (null? xs) #t (error 'large-heap "extra chunks"))
      (let ((s (car xs)) (ch (integer->char (+ 32 n))))
        (if (and (= (string-length s) chunk-size)
                 (char=? (string-ref s 0) ch)
                 (char=? (string-ref s (- chunk-size 1)) ch))
            (check-chunks (cdr xs) (- n 1))
            (error 'large-heap "corrupt live buffer" n)))))
(define live-chunks (chunks 40))
(define before (gc-count))
(gc)
(check-chunks live-chunks 40)
(if (> (gc-count) before) #t (error 'large-heap "collection missing"))
; This is a live-capacity test, not an exact-liveness test: conservative roots
; can retain interpreted call frames even after a binding is cleared. Native
; GC fixtures separately prove reclamation, reuse and arena-tail coalescing.
(display "ok - 160 MiB live buffers survive collection\n")
