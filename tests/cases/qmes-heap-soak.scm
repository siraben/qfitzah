; P1 Part C gate: host-heap reclamation under a long trampoline soak.
;
; A niladic tail loop that, every iteration, conses a throwaway list, then
; resets the cell arena back to a fixed post-startup floor, for 50 million
; iterations.  Without the reset this conses on the order of 10^10 bytes and
; would blow the cell arena (many times over the 192 MiB->bumped size) and
; SIGSEGV; with a correct reset it runs in constant memory and exits 0.
;
; Discipline (see plan Sec 2.1): all state carried across a reset lives in
; globals or immediates, never in a frame above the floor -- so the loop
; counter is a global fixnum and the loop takes no arguments.  The floor is
; captured AFTER every persistent global (incl. the garbage/tramp closures)
; is allocated, and is offset above its own w32 box so the box itself survives
; each reset.  `survivor` (a heap pair allocated before the floor) and
; `counter` (a global fixnum) must be intact after all the resets.

(define survivor (cons 111 (cons 222 (cons 333 '()))))
(define counter 0)
(define LIM 50000000)
(define (garbage n) (if (= n 0) '() (cons n (garbage (- n 1)))))
(define (tramp)
  (if (< counter LIM)
      (begin
        (garbage 8)                 ; throwaway conses (dead after the reset)
        (host-heap-reset! rf)       ; reclaim them: GCellFree <- floor
        (set! counter (+ counter 1))
        (tramp))
      'done))
; Floor captured last; +64 keeps the floor's own w32 box below the reset point.
(define rf (w32-add (host-heap-mark) (w32-from-fixnum 64)))
(tramp)
(display "counter: ") (display counter) (newline)
(display "survivor: ") (write survivor) (newline)
