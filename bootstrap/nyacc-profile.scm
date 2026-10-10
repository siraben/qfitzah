; Optional phase tracing; this changes no grammar or generated table contents.
; Run from the prepared Nyacc tree with -- SCRIPT where SCRIPT is an upstream
; gen-*-files.scm. The wrappers invoke the original source procedures.
(use-modules (nyacc lalr))
(define lalr-module (resolve-module '(nyacc lalr)))
(define (trace-procedure name)
  (let ((original (module-ref lalr-module name)))
    (module-define! lalr-module name
      (lambda args
        (display name) (display " begin\n")
        (let ((result (apply original args)))
          (display name) (display " done; gc=") (write (gc-count)) (newline)
          result)))))
(for-each trace-procedure
          '(process-spec make-lalr-machine step1 step2 step3 step4 hashify-machine compact-machine))
(let ((arguments (cdr (command-line))))
  (if (= (length arguments) 1) (load (car arguments))
      (error 'nyacc-profile "expected one generator script")))
(display "generation complete\n")
