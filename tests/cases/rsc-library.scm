; Stage 4 corpus: the standard-library prelude (all names come from the prelude
; rsc prepends; this program defines none of them).

; list ops
(display "append: ") (write (append '(1 2) '(3 4) '(5))) (newline)
(display "reverse: ") (write (reverse '(a b c d))) (newline)
(display "length: ") (display (length '(1 2 3 4 5))) (newline)
(display "list-ref: ") (display (list-ref '(a b c d) 2)) (newline)
(display "list-tail: ") (write (list-tail '(1 2 3 4) 2)) (newline)
(display "map: ") (write (map (lambda (x) (* x x)) '(1 2 3 4))) (newline)
(display "for-each: ") (for-each (lambda (x) (display x) (display " ")) '(a b c)) (newline)

; equality / association
(display "equal?: ") (write (list (equal? '(1 (2 3)) '(1 (2 3)))
                                   (equal? "abc" "abc") (equal? '(1) '(2)))) (newline)
(display "assoc: ") (write (assoc 'b '((a . 1) (b . 2) (c . 3)))) (newline)
(display "member: ") (write (member 3 '(1 2 3 4))) (newline)
(display "memv: ") (write (memv 9 '(1 2 3))) (newline)

; numbers
(display "abs/mod/gcd: ")
(write (list (abs -7) (modulo -7 3) (modulo 7 -3) (gcd 48 36) (min 3 1 2) (max 3 1 2))) (newline)
(display "even/odd/zero: ") (write (list (even? 4) (odd? 4) (zero? 0) (positive? -1))) (newline)
(display "number->string: ") (write (list (number->string 0) (number->string 42)
                                          (number->string -1234))) (newline)

; chars
(display "char-cmp: ") (write (list (char<? #\a #\b) (char=? #\x #\x) (char>? #\a #\b))) (newline)
(display "char-class: ") (write (list (char-alphabetic? #\A) (char-numeric? #\7)
                                      (char-whitespace? #\space))) (newline)
(display "char-case: ") (write (list (char-upcase #\a) (char-downcase #\Q))) (newline)

; strings
(display "string ops: ")
(write (list (string-append "foo" "bar") (substring "hello world" 0 5)
             (string->list "hi") (string #\a #\b #\c))) (newline)
(display "string-cmp: ") (write (list (string=? "abc" "abc") (string<? "abc" "abd")
                                      (string<? "ab" "abc"))) (newline)
(display "string-copy: ") (write (string-copy "copied")) (newline)
