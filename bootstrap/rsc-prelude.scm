; rsc-prelude.scm -- the R5RS standard-library layer of the bootstrap ladder.
;
; This is a fixed block of Scheme source that the build/test harness prepends
; (as text, on stdin) to every program rsc compiles, so a user program can
; rely on the R5RS library procedures below.  It is a separate compilation
; unit rather than data embedded in rsc.scm: embedding it as a quoted literal
; bloated the self-hosted compiler's static data and its seed assembly time,
; so rsc stays lean and the prelude is prepended as text.  rsc.scm itself
; uses NONE of these definitions -- that is what keeps its self-host fixpoint
; a pure exercise of the sc1 core.
;
; Everything here is written in the sc1 core subset atop the runtime
; primitives (cons, car, +, string-ref, vector-set!, ...), so the definitions
; double as an executable specification of each library procedure.  Every
; loop is tail-recursive (accumulator style) or naturally bounded by its
; input, per the compiler's constant-stack tail calls.  Where R5RS
; distinguishes eq?/eqv?/equal? tiers (memq/memv/member, assq/assv/assoc)
; all three are provided.

; --- pair and list procedures (R5RS 6.3.2) ---------------------------------
(define (list . xs) xs)
(define (caar x) (car (car x)))
(define (cadr x) (car (cdr x)))
(define (cdar x) (cdr (car x)))
(define (cddr x) (cdr (cdr x)))
(define (caddr x) (car (cddr x)))
(define (cdddr x) (cdr (cddr x)))
(define (cadddr x) (car (cdddr x)))
(define (not x) (if x #f #t))
; append is variadic via a rest parameter; the two-list worker recurses on
; the first list only, so the last argument is shared, as R5RS permits.
(define (append2* a b) (if (null? a) b (cons (car a) (append2* (cdr a) b))))
(define (append-list ls)
  (cond ((null? ls) '())
        ((null? (cdr ls)) (car ls))
        (else (append2* (car ls) (append-list (cdr ls))))))
(define (append . ls) (append-list ls))
(define (reverse-onto l acc) (if (null? l) acc (reverse-onto (cdr l) (cons (car l) acc))))
(define (reverse l) (reverse-onto l '()))
(define (length-acc l n) (if (null? l) n (length-acc (cdr l) (+ n 1))))
(define (length l) (length-acc l 0))
(define (list-tail l k) (if (= k 0) l (list-tail (cdr l) (- k 1))))
(define (list-ref l k) (car (list-tail l k)))
; Single-list map/for-each only -- all the ladder's sources need.
(define (map f l) (if (null? l) '() (cons (f (car l)) (map f (cdr l)))))
(define (for-each f l) (if (null? l) #f (begin (f (car l)) (for-each f (cdr l)))))

; --- equivalence (R5RS 6.1) ------------------------------------------------
; equal? recurses structurally through pairs, compares strings by contents,
; vectors via their list form, and bottoms out in eqv? (a runtime primitive).
(define (equal? a b)
  (cond ((and (pair? a) (pair? b))
         (and (equal? (car a) (car b)) (equal? (cdr a) (cdr b))))
        ((and (string? a) (string? b)) (string=? a b))
        ((and (vector? a) (vector? b)) (equal? (vector->list a) (vector->list b)))
        (else (eqv? a b))))
(define (memq x l) (cond ((null? l) #f) ((eq? x (car l)) l) (else (memq x (cdr l)))))
(define (memv x l) (cond ((null? l) #f) ((eqv? x (car l)) l) (else (memv x (cdr l)))))
(define (member x l) (cond ((null? l) #f) ((equal? x (car l)) l) (else (member x (cdr l)))))
(define (assq x l) (cond ((null? l) #f) ((eq? x (caar l)) (car l)) (else (assq x (cdr l)))))
(define (assv x l) (cond ((null? l) #f) ((eqv? x (caar l)) (car l)) (else (assv x (cdr l)))))
(define (assoc x l) (cond ((null? l) #f) ((equal? x (caar l)) (car l)) (else (assoc x (cdr l)))))

; --- numbers (R5RS 6.2.5); fixnums only ------------------------------------
(define (zero? n) (= n 0))
(define (positive? n) (> n 0))
(define (negative? n) (< n 0))
(define (abs n) (if (< n 0) (- 0 n) n))
(define (even? n) (= (remainder n 2) 0))
(define (odd? n) (not (even? n)))
; remainder (the primitive) truncates toward zero; modulo must instead take
; the sign of the divisor, so shift a nonzero remainder by b when the signs
; disagree.
(define (modulo a b)
  (let ((r (remainder a b)))
    (if (= r 0) 0 (if (eq? (< r 0) (< b 0)) r (+ r b)))))
(define (min a . r) (min-list a r))
(define (min-list a r) (if (null? r) a (min-list (if (< (car r) a) (car r) a) (cdr r))))
(define (max a . r) (max-list a r))
(define (max-list a r) (if (null? r) a (max-list (if (> (car r) a) (car r) a) (cdr r))))
(define (gcd a b) (if (= b 0) (abs a) (gcd b (remainder a b))))
; number->string, base 10 only: peel digits low-to-high, consing them onto
; the accumulator puts them back in reading order.
(define (nd-loop n acc)
  (if (= n 0) acc (nd-loop (quotient n 10) (cons (integer->char (+ 48 (remainder n 10))) acc))))
(define (num->digits n) (if (= n 0) (list #\0) (nd-loop n '())))
(define (number->string n)
  (if (< n 0)
      (list->string (cons #\- (num->digits (- 0 n))))
      (list->string (num->digits n))))

; --- characters (R5RS 6.3.4); ASCII throughout -----------------------------
(define (char=? a b) (= (char->integer a) (char->integer b)))
(define (char<? a b) (< (char->integer a) (char->integer b)))
(define (char>? a b) (< (char->integer b) (char->integer a)))
(define (char<=? a b) (not (< (char->integer b) (char->integer a))))
(define (char>=? a b) (not (< (char->integer a) (char->integer b))))
(define (char-upper? c) (let ((i (char->integer c))) (and (> i 64) (< i 91))))
(define (char-lower? c) (let ((i (char->integer c))) (and (> i 96) (< i 123))))
(define (char-alphabetic? c) (or (char-upper? c) (char-lower? c)))
(define (char-numeric? c) (let ((i (char->integer c))) (and (> i 47) (< i 58))))
(define (char-whitespace? c)
  (let ((i (char->integer c))) (or (= i 32) (= i 9) (= i 10) (= i 13))))
(define (char-upcase c) (if (char-lower? c) (integer->char (- (char->integer c) 32)) c))
(define (char-downcase c) (if (char-upper? c) (integer->char (+ (char->integer c) 32)) c))

; --- strings (R5RS 6.3.5) --------------------------------------------------
; Built on the string-length/string-ref/list->string primitives; construction
; goes through character lists, which is O(n) garbage but simple, and these
; run at compile time of the NEXT stage, not in any inner loop.
(define (str->list-loop s i n) (if (= i n) '() (cons (string-ref s i) (str->list-loop s (+ i 1) n))))
(define (string->list s) (str->list-loop s 0 (string-length s)))
(define (string . cs) (list->string cs))
(define (string-append . ss) (list->string (append-list (map string->list ss))))
(define (sub-loop s a b) (if (< a b) (cons (string-ref s a) (sub-loop s (+ a 1) b)) '()))
(define (substring s a b) (list->string (sub-loop s a b)))
(define (string-copy s) (substring s 0 (string-length s)))
(define (str-eq a b i n)
  (if (= i n) #t (and (char=? (string-ref a i) (string-ref b i)) (str-eq a b (+ i 1) n))))
(define (string=? a b)
  (and (= (string-length a) (string-length b)) (str-eq a b 0 (string-length a))))
; Lexicographic order; a proper prefix is smaller.
(define (str-lt a b i na nb)
  (cond ((= i na) (< na nb))
        ((= i nb) #f)
        ((char<? (string-ref a i) (string-ref b i)) #t)
        ((char>? (string-ref a i) (string-ref b i)) #f)
        (else (str-lt a b (+ i 1) na nb))))
(define (string<? a b) (str-lt a b 0 (string-length a) (string-length b)))

; --- vectors (R5RS 6.3.6) --------------------------------------------------
(define (vfill v x i n) (if (< i n) (begin (vector-set! v i x) (vfill v x (+ i 1) n)) #f))
(define (vector-fill! v x) (vfill v x 0 (vector-length v)))
