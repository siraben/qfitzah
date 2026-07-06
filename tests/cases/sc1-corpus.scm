; Stage 3 corpus: exercises the sc1-compiled language end to end. Every helper
; is defined in-program because the compiled program is self-contained.
(define (list . xs) xs)
(define (map1 f l) (if (null? l) '() (cons (f (car l)) (map1 f (cdr l)))))
(define (append2 a b) (if (null? a) b (cons (car a) (append2 (cdr a) b))))
(define (reverse-onto l acc) (if (null? l) acc (reverse-onto (cdr l) (cons (car l) acc))))
(define (reverse l) (reverse-onto l '()))

; arithmetic / non-tail recursion
(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
(display "fact 10 = ") (display (fact 10)) (newline)
(display "quot/rem: ") (display (quotient 17 5)) (display " ") (display (remainder -17 5)) (newline)

; higher-order functions, map defined in Scheme
(write (map1 (lambda (x) (* x x)) '(1 2 3 4 5))) (newline)
(write (append2 '(1 2 3) '(4 5 6))) (newline)
(write (reverse '(a b c d))) (newline)

; closures: a counter captured by set!
(define (make-counter)
  (let ((n 0))
    (lambda () (set! n (+ n 1)) n)))
(define c (make-counter))
(display (c)) (display (c)) (display (c)) (newline)

; quoted nested data + string->symbol round trip
(write '(nested (deep . pair) #t #f 42 -7 #\z "lit")) (newline)
(display (eq? 'round-trip (string->symbol "round-trip"))) (newline)
(display (symbol->string 'hello-world)) (newline)

; strings and characters
(display "len=") (display (string-length "scheme")) (newline)
(display "ref1=") (display (string-ref "scheme" 1)) (newline)
(display (char->integer #\A)) (display " ") (write (integer->char 98)) (newline)

; predicates and conditionals
(display (list (pair? '(1)) (null? '()) (number? 3) (symbol? 'x)
               (string? "s") (char? #\q) (boolean? #f) (procedure? car))) (newline)
(display (cond ((= 1 2) 'no) ((< 3 4) 'yes) (else 'else))) (newline)
(display (list (and 1 2 3) (or #f #f 7) (not #f))) (newline)
