; Direct SKI bracket abstraction, matching singularity's unlam/babs algorithm.
; K t when x is not free; I for x; S ([x]a) ([x]b) for an application.
;
; ELIMINATE LAMBDAS WITHOUT EVALUATING THE PROGRAM
; ----------------------------------------------
; Write [x]t for a combinator expression that, given x's value, computes t.
; The VM supplies I x = x, K t x = t, and S f g x = (f x) (g x).
; These equations explain all three cases in sg-abstract below. For example:
;   [x]x       = I
;   [x]y       = K y          (y differs from x)
;   [x](f x)   = S (K f) I
; We deliberately do NOT shorten the last example to f by eta reduction:
; reproducing singularity's actual output requires the same abstraction rules,
; not merely a compiler producing extensionally equivalent programs.
;
; sg-lower works inside-out. Before abstracting an outer binder, eliminate
; every lambda in its body; sg-free? and sg-abstract consequently need only
; raw, var and app nodes. A name left after lowering must denote a global.
; Shadowing follows from that order: in \x -> (\x -> x), the inner expression
; becomes I before the outer binder is considered, giving K I.
(define (sg-free? name expr)
  (case (vector-ref expr 0)
    ((raw) #f)
    ((var) (eq? name (vector-ref expr 1)))
    ((app) (or (sg-free? name (vector-ref expr 1))
               (sg-free? name (vector-ref expr 2))))
    (else (sg-error "unexpected lambda during abstraction"))))
(define (sg-abstract name expr)
  (cond ((not (sg-free? name expr)) (vector 'app (vector 'raw "K") expr))
        ((eq? (vector-ref expr 0) 'var) (vector 'raw "I"))
        (else (vector 'app
                (vector 'app (vector 'raw "S") (sg-abstract name (vector-ref expr 1)))
                (sg-abstract name (vector-ref expr 2))))))
(define (sg-lower expr)
  (case (vector-ref expr 0)
    ((raw var) expr)
    ((app) (vector 'app (sg-lower (vector-ref expr 1)) (sg-lower (vector-ref expr 2))))
    ((lam) (sg-abstract (vector-ref expr 1) (sg-lower (vector-ref expr 2))))
    (else (sg-error "invalid expression node"))))
; Global references are a byte after @, encoded as index+32. Indices 0..223
; fill the available byte range 32..255; definition 225 must be rejected.
; Keep source order even though this association table is built in reverse:
; the stored index, not the table's list position, determines the encoding.
(define (sg-symbols defs)
  (let loop ((defs defs) (index 0) (out '()))
    (if (null? defs) out
        (if (>= index 224) (sg-error "ION byte-index table exhausted")
            (loop (cdr defs) (+ index 1) (cons (cons (caar defs) index) out))))))
(define (sg-index name symbols)
  (let ((entry (assq name symbols)))
    (if entry (cdr entry) (sg-error (list 'unbound-variable name)))))
; The VM fills global entries sequentially. While defining entry limit, only
; indices below limit exist. Even a self-reference is therefore invalid here;
; recursion must be expressed through the raw fixed-point primitive @Y in the
; SOURCE. Validate lowered trees so lambda-bound names are not mistaken for
; missing globals. main runs this over every definition before emitting bytes.
(define (sg-validate expr symbols limit)
  (case (vector-ref expr 0)
    ((var) (let ((name (vector-ref expr 1)))
             (if (>= (sg-index name symbols) limit)
                 (sg-error (list 'unsupported-forward-reference name)) #t)))
    ((app) (sg-validate (vector-ref expr 1) symbols limit)
           (sg-validate (vector-ref expr 2) symbols limit))
    ((raw) #t)
    (else (sg-error "unlowered node"))))
; Serialization is prefix notation: ` introduces an application, @ plus a
; byte selects a global, and raw nodes already contain their VM encoding.
; main supplies the semicolon after each definition. Thus "ident x = x;
; main = ident;" emits "I;@ ;" (the space is index zero, not ignorable layout).
; No host assembler or opaque starting image participates in this emission.
(define (sg-emit expr symbols)
  (case (vector-ref expr 0)
    ((raw) (display (vector-ref expr 1)))
    ((var) (display "@")
           (write-char (integer->char (+ 32 (sg-index (vector-ref expr 1) symbols)))))
    ((app) (display "`") (sg-emit (vector-ref expr 1) symbols)
           (sg-emit (vector-ref expr 2) symbols))
    (else (sg-error "unlowered output node"))))
