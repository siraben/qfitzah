; Scatter small live cells among temporary buffers, then request a larger
; contiguous allocation. A single first-fit arena fails despite ample free
; space; a separate large-block arena must remain available.
(define anchors '())
(define (scatter n)
  (if (= n 0) #t
      (let ((garbage (make-string 512 #\x)))
        (set! anchors (cons (cons n n) anchors))
        (scatter (- n 1)))))
(scatter 300)
(gc)
(define big (make-vector 8192 (car anchors)))
(set! anchors #f)
(vector-set! big 4096 big)
(gc)
(write (vector-length big)) (newline)
(write (car (vector-ref big 0))) (newline)
(write (eq? (vector-ref big 4096) big)) (newline)
; Traced vector storage and atomic bytes share the large arena safely.
(define bytes (make-string 8192 #\z))
(gc)
(write (char=? (string-ref bytes 8191) #\z)) (newline)
(set! big #f)
(set! bytes #f)
(string-ref (make-string 1 #\y) 0)
(gc)
; This request spans the reclaimed large-arena tail and never-used bump space.
(define larger (make-string 49152 #\w))
(gc)
(write (char=? (string-ref larger 49151) #\w)) (newline)
