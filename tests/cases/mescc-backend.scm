; Exercise the real MesCC instruction selector and M1 writer without a C parser.
; This is an IR-level smoke test, not evidence of C compilation.
(use-modules (mescc info) (mescc i386 info) (mescc as) (mescc M1))
(define info (x86-info))
(define text
  (list (as info 'function-preamble)
        (as info 'label->r "answer")
        (as info 'mem->r)
        (as info 'ret)))
(define main-function (make-function "main" (assoc-ref (.types info) "int") text))
(define answer (make-global "answer" (assoc-ref (.types info) "int") (int->bv32 42) #f #f))
(info->M1 "backend-probe.s"
          (clone info #:functions (list (cons "main" main-function))
                      #:globals (list (cons "answer" answer)))
          #:align '(functions globals))
