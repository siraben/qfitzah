; sc1 reader: reads Scheme data from the current input using read-char and
; peek-char. Written in the scheme0 subset (top-level define, lambda, if,
; cond, let, and, or, begin, quote, set!, and the scheme0 primitives), which
; is also the subset sc1 compiles, so this file serves both the interpreted
; and the self-compiled compiler.

(define (list . xs) xs)

(define (cadr x) (car (cdr x)))
(define (cddr x) (cdr (cdr x)))
(define (caddr x) (car (cddr x)))

(define (append2 a b)
  (if (null? a) b (cons (car a) (append2 (cdr a) b))))

(define (reverse-onto l acc)
  (if (null? l) acc (reverse-onto (cdr l) (cons (car l) acc))))

(define (reverse l) (reverse-onto l '()))

(define (length-acc l n) (if (pair? l) (length-acc (cdr l) (+ n 1)) n))
(define (length l) (length-acc l 0))

(define (memq x l)
  (cond ((null? l) #f)
        ((eq? x (car l)) l)
        (else (memq x (cdr l)))))

(define (assq x l)
  (cond ((null? l) #f)
        ((eq? x (car (car l))) (car l))
        (else (assq x (cdr l)))))

; character classes
(define (rd-ws? c)
  (or (eq? c #\space) (eq? c #\newline) (eq? c #\tab)
      (eq? c (integer->char 13))))

(define (rd-digit? c)
  (and (char? c)
       (not (< (char->integer c) 48))
       (not (< 57 (char->integer c)))))

(define (rd-delim? c)
  (or (eof-object? c) (rd-ws? c)
      (eq? c #\() (eq? c #\)) (eq? c #\") (eq? c #\;)))

(define (rd-skip-line)
  (let ((c (read-char)))
    (if (or (eof-object? c) (eq? c #\newline)) #f (rd-skip-line))))

(define (rd-skip-ws)
  (let ((c (peek-char)))
    (cond ((eof-object? c) #f)
          ((rd-ws? c) (read-char) (rd-skip-ws))
          ((eq? c #\;) (rd-skip-line) (rd-skip-ws))
          (else #f))))

(define (rd-token-chars acc)
  (if (rd-delim? (peek-char))
      (reverse acc)
      (rd-token-chars (cons (read-char) acc))))

(define (rd-number neg acc)
  (if (rd-digit? (peek-char))
      (rd-number neg (+ (* acc 10) (- (char->integer (read-char)) 48)))
      (if neg (- 0 acc) acc)))

(define (rd-string acc)
  (let ((c (read-char)))
    (cond ((eof-object? c) (error 'reader "eof in string"))
          ((eq? c #\") (list->string (reverse acc)))
          ((eq? c (integer->char 92))
           (let ((e (read-char)))
             (cond ((eq? e #\n) (rd-string (cons #\newline acc)))
                   ((eq? e #\t) (rd-string (cons #\tab acc)))
                   (else (rd-string (cons e acc))))))
          (else (rd-string (cons c acc))))))

(define (rd-hash)
  (let ((c (read-char)))
    (cond ((eq? c #\t) #t)
          ((eq? c #\f) #f)
          ((eq? c (integer->char 92))
           (let ((first (read-char)))
             (if (rd-delim? (peek-char))
                 first
                 (let ((name (cons first (rd-token-chars '()))))
                   (cond ((eq? first #\s) #\space)
                         ((eq? first #\n) #\newline)
                         ((eq? first #\t) #\tab)
                         (else (error 'reader "bad char name")))))))
          (else (error 'reader "bad # syntax")))))

(define (rd-list)
  (rd-skip-ws)
  (let ((c (peek-char)))
    (cond ((eof-object? c) (error 'reader "eof in list"))
          ((eq? c #\)) (read-char) '())
          ((eq? c #\.)
           (read-char)
           (if (rd-delim? (peek-char))
               (let ((tail (rd)))
                 (rd-skip-ws)
                 (if (eq? (read-char) #\))
                     tail
                     (error 'reader "bad dotted list")))
               (let ((sym (rd-symbol-from (cons #\. (rd-token-chars '())))))
                 (cons sym (rd-list)))))
          (else (let ((head (rd)))
                  (cons head (rd-list)))))))

(define (rd-symbol-from chars)
  (string->symbol (list->string chars)))

(define (rd)
  (rd-skip-ws)
  (let ((c (peek-char)))
    (cond ((eof-object? c) c)
          ((eq? c #\() (read-char) (rd-list))
          ((eq? c #\)) (error 'reader "unexpected )"))
          ((eq? c #\') (read-char) (list 'quote (rd)))
          ((eq? c #\`) (read-char) (list 'quasiquote (rd)))
          ((eq? c #\,)
           (read-char)
           (if (eq? (peek-char) #\@)
               (begin (read-char) (list 'unquote-splicing (rd)))
               (list 'unquote (rd))))
          ((eq? c #\") (read-char) (rd-string '()))
          ((eq? c #\#) (read-char) (rd-hash))
          ((rd-digit? c) (rd-number #f 0))
          ((eq? c #\-)
           (read-char)
           (if (rd-digit? (peek-char))
               (rd-number #t 0)
               (rd-symbol-from (cons #\- (rd-token-chars '())))))
          (else (rd-symbol-from (rd-token-chars '()))))))
