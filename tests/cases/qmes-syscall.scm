; P1 Part B: syscalls + process environment.  The bash runner in tests/run.sh
; drives this with a known env var (QMES_TESTVAR), known argv (ARG_ALPHA
; ARG_BETA <datafile>), and a datafile of known contents, so the transcript
; below is deterministic.  argv[0] (a temp path) is never printed.
(display (getenv "QMES_TESTVAR")) (newline)          ; the runner-set value
(display (getenv "QMES_ABSENT_VAR_XYZ")) (newline)   ; #f (not present)
(define cl (command-line))
(display (list-ref cl 1)) (newline)                  ; ARG_ALPHA
(display (list-ref cl 2)) (newline)                  ; ARG_BETA
; open + read the datafile named by argv[3]; print its contents, not its path
(define fd (sys-open (list-ref cl 3) 0 0))
(display (>= fd 0)) (newline)                         ; #t
(define buf (make-string 64))
(define n (sys-read fd buf))
(display (substring buf 0 n)) (newline)               ; datafile contents
(sys-close fd)
; sys-write straight to stdout (fd 1)
(define msg (make-string 4))
(string-set! msg 0 #\O) (string-set! msg 1 #\K)
(string-set! msg 2 #\!) (string-set! msg 3 #\newline)
(sys-write 1 msg 4)
