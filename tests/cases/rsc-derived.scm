; Stage 4 corpus: derived special forms and quasiquote (prelude provides
; list/append/map used by expansions and by quasiquote).

; let* -- sequential binding
(display "let*: ") (display (let* ((a 1) (b (+ a 1)) (c (+ b 1))) (list a b c))) (newline)

; letrec -- mutual recursion
(display "letrec: ")
(display (letrec ((ev? (lambda (n) (if (= n 0) #t (od? (- n 1)))))
                  (od? (lambda (n) (if (= n 0) #f (ev? (- n 1))))))
           (list (ev? 10) (od? 10))))
(newline)

; named let
(display "named-let: ")
(display (let loop ((i 0) (acc '()))
           (if (= i 5) (reverse acc) (loop (+ i 1) (cons (* i i) acc)))))
(newline)

; when / unless
(display "when: ") (display (when (> 3 2) 'yes)) (newline)
(display "unless: ") (display (unless (> 2 3) 'ran)) (newline)

; case
(define (classify n)
  (case n
    ((1 3 5 7 9) 'odd)
    ((0 2 4 6 8) 'even)
    (else 'big)))
(display "case: ") (display (list (classify 3) (classify 4) (classify 42))) (newline)

; cond with =>
(display "cond=>: ")
(display (cond ((assv 2 (list (cons 1 'a) (cons 2 'b))) => cdr) (else 'none)))
(newline)

; do loop
(display "do: ")
(display (do ((i 0 (+ i 1)) (s 0 (+ s i))) ((= i 5) s)))
(newline)

; quasiquote, nested, with unquote and unquote-splicing
(define xs (list 1 2 3))
(display "qq1: ") (write `(a b ,(+ 1 2) ,@xs z)) (newline)
(display "qq2: ") (write `(1 `(2 ,(3 ,(+ 4 5))))) (newline)
(display "qq3: ") (write `(head ,@(map (lambda (x) (* x 10)) xs) tail)) (newline)
