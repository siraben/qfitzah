; Upstream option parsing needed by MesCC's -S frontend.
(use-modules ((mes mes-0) #:select (mes? guile? guile-1.8? guile-2?)))
(write (list mes? guile? guile-1.8? guile-2?)) (newline)
(use-modules (ice-9 getopt-long))
(define grammar
  '((compile (single-char #\S))
    (output (single-char #\o) (value #t))
    (include (single-char #\I) (value #t))
    (define (single-char #\D) (value #t))))
(define options
  (getopt-long '("mescc" "-S" "-o" "out.s" "-I" "inc"
                "--define=ANSWER=42" "source.c" "--" "--literal") grammar))
(write (map (lambda (key) (option-ref options key 'missing))
            '(compile output include define () absent))) (newline)
(write (catch 'misc-error
         (lambda () (getopt-long '("mescc" "-o") grammar))
         (lambda args 'missing-value))) (newline)
; The writer interface uses our port representation, not Mes's raw VM cells.
(mes-use-module (mes display))
(write '(a #f . #f)) (newline)
(write (call-with-output-string
         (lambda (port) (display "ok" port) (write '(1 2) port)))) (newline)
