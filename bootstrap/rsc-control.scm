; Dynamic control over control.qf1. Compile with rsc after rsc-prelude.scm.
; Native call/cc captures stack only; this layer handles dynamic-wind, values,
; exception handlers and fluid bindings in ordinary, GC-visible Scheme data.
(define %native-call/cc call-with-current-continuation)
(define %winds '())
(define %values-tag (list 'values))
(define (values . xs)
  (if (and (pair? xs) (null? (cdr xs))) (car xs) (vector %values-tag xs)))
(define (%multiple-values? x)
  (and (vector? x) (= (vector-length x) 2) (eq? (vector-ref x 0) %values-tag)))
(define (call-with-values producer consumer)
  (let ((x (producer)))
    (if (%multiple-values? x) (apply consumer (vector-ref x 1)) (consumer x))))

; Wind stacks share tails by identity. Align lengths before finding the LCA.
(define (%wind-align xs n)
  (if (= n 0) xs (%wind-align (cdr xs) (- n 1))))
(define (%wind-common a b)
  (if (eq? a b) a (%wind-common (cdr a) (cdr b))))
(define (%wind-leave common)
  (if (eq? %winds common) #t
      (let ((frame (car %winds)))
        (set! %winds (cdr %winds))
        ((cdr frame))
        (%wind-leave common))))
(define (%wind-enter target common)
  (if (eq? target common) #t
      (begin (%wind-enter (cdr target) common)
             ((car (car target)))
             (set! %winds target))))
(define (%wind-to target)
  (let* ((a (length %winds)) (b (length target))
         (common (%wind-common (%wind-align %winds (max 0 (- a b)))
                               (%wind-align target (max 0 (- b a))))))
    (%wind-leave common)
    (%wind-enter target common)))
(define (call-with-current-continuation proc)
  (let ((target %winds))
    (%native-call/cc
      (lambda (resume)
        (proc (lambda args (%wind-to target) (resume (apply values args))))))))
(define call/cc call-with-current-continuation)
(define (dynamic-wind before thunk after)
  (before)
  (let ((old %winds))
    (set! %winds (cons (cons before after) old))
    (let ((result (thunk)))
      (set! %winds old)
      (after)
      result)))

; Exceptions use dynamic handler stacks. A catch escape returns a thunk so
; its handler executes AFTER leaving the catch's extent. Throw handlers and
; optional pre-unwind handlers execute before unwinding, with themselves
; disabled to permit rethrowing without recursion.
(define %handlers '())
(define %fatal-error error)
(define %unhandled-exception
  (lambda (key args) (apply %fatal-error (cons key args))))
(define (%with-handlers handlers thunk)
  (let ((old %handlers))
    (dynamic-wind (lambda () (set! %handlers handlers))
                  thunk
                  (lambda () (set! %handlers old)))))
(define (catch key thunk handler . rest)
  ((call/cc
     (lambda (escape)
       (let ((frame (vector 'catch key handler escape
                            (if (null? rest) #f (car rest)))))
         (%with-handlers (cons frame %handlers)
           (lambda () (let ((result (thunk))) (lambda () result)))))))))
(define (with-throw-handler key thunk handler)
  (%with-handlers (cons (vector 'handler key handler #f #f) %handlers) thunk))
(define (%handler-matches? frame key)
  (or (eq? (vector-ref frame 1) #t) (eq? (vector-ref frame 1) key)))
(define (%run-throw-handler handler tail key args)
  (%with-handlers tail (lambda () (apply handler (cons key args)))))
(define (%throw-to frames key args)
  (if (null? frames) (%unhandled-exception key args)
      (let ((frame (car frames)) (tail (cdr frames)))
        (cond ((not (%handler-matches? frame key)) (%throw-to tail key args))
              ((eq? (vector-ref frame 0) 'handler)
               (%run-throw-handler (vector-ref frame 2) tail key args)
               (%throw-to tail key args))
              (else
                (if (vector-ref frame 4)
                    (%run-throw-handler (vector-ref frame 4) tail key args) #f)
                ((vector-ref frame 3)
                 (lambda () (apply (vector-ref frame 2) (cons key args)))))))))
(define (throw key . args) (%throw-to %handlers key args))
(define (error . args) (apply throw (cons 'misc-error args)))

(define %fluid-tag (list 'fluid))
(define (make-fluid . rest)
  (vector %fluid-tag (if (null? rest) #f (car rest))))
(define (fluid? x)
  (and (vector? x) (= (vector-length x) 2) (eq? (vector-ref x 0) %fluid-tag)))
(define (fluid-ref f) (vector-ref f 1))
(define (fluid-set! f value) (vector-set! f 1 value))
(define (%swap-fluid-bindings bindings)
  (if (null? bindings) #t
      (let* ((binding (car bindings)) (fluid (car binding)) (old (fluid-ref fluid)))
        (fluid-set! fluid (cdr binding))
        (set-cdr! binding old)
        (%swap-fluid-bindings (cdr bindings)))))
(define (%with-fluids bindings thunk)
  (dynamic-wind (lambda () (%swap-fluid-bindings bindings)) thunk
                (lambda () (%swap-fluid-bindings (reverse bindings)))))
(define-syntax with-fluids
  (syntax-rules ()
    ((_ ((fluid value) ...) body ...)
     (%with-fluids (list (cons fluid value) ...) (lambda () body ...)))))
