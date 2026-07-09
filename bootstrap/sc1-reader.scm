; sc1-reader.scm -- the S-expression reader shared by the sc1 and rsc
; compilers (Stages 3 and 4 of the bootstrap ladder).
;
; Role in the ladder: this file is the first thing concatenated onto stdin in
; every sc1/rsc build.  The scheme0 interpreter (Stage 2) evaluates it to get
; a `rd` procedure, then evaluates the compiler that follows it, and THAT uses
; `rd` to read the program text that follows on the same stream.  When the
; compiler compiles itself, this file appears twice on stdin: once as code for
; the interpreter, once as data for the compiler.  So the same source both
; runs interpreted and is compiled into the native compiler binary -- which is
; why the self-hosted fixpoint reads its input with exactly this reader.
;
; It is written in the scheme0 subset (top-level define, lambda, if, cond,
; let, and, or, begin, quote, set!, and the scheme0 primitives), which is also
; the subset sc1 compiles.  Input comes from the current input port via the
; read-char / peek-char primitives only; `rd` returns one datum per call, or
; the eof object at end of input.
;
; Trust framing: this reader replaces the seed's much cruder S-expression
; parser as soon as Scheme exists.  It is small enough to audit in one
; sitting, and everything above it in the ladder (sc1, rsc, asm, qmes) is
; read -- and therefore trusted -- through it.

; ---------------------------------------------------------------------------
; List utilities.  scheme0 provides cons/car/cdr and friends as primitives
; but almost no library, so the handful of helpers the reader needs are
; defined right here (the compilers that follow reuse them too).
; ---------------------------------------------------------------------------

(define (list . xs) xs)

(define (cadr x) (car (cdr x)))
(define (cddr x) (cdr (cdr x)))
(define (caddr x) (car (cddr x)))

(define (append2 a b)
  (if (null? a) b (cons (car a) (append2 (cdr a) b))))

; reverse via an accumulator: tail-recursive, so it runs in constant stack
; under scheme0's (and sc1's) proper tail calls.
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

; ---------------------------------------------------------------------------
; Character classes.  Kept deliberately simple: whitespace is space, newline,
; tab, CR; a delimiter is anything that ends a token.  Characters are compared
; with eq? -- scheme0 represents a character as a tagged immediate, so eq? is
; character equality.
; ---------------------------------------------------------------------------

(define (rd-ws? c)
  (or (eq? c #\space) (eq? c #\newline) (eq? c #\tab)
      (eq? c (integer->char 13))))

; Guard with char? first: peek-char may hand us the eof object.
(define (rd-digit? c)
  (and (char? c)
       (not (< (char->integer c) 48))
       (not (< 57 (char->integer c)))))

(define (rd-delim? c)
  (or (eof-object? c) (rd-ws? c)
      (eq? c #\() (eq? c #\)) (eq? c #\") (eq? c #\;)))

; ---------------------------------------------------------------------------
; Whitespace and comments.  A `;` comment runs to end of line, as in R5RS.
; ---------------------------------------------------------------------------

(define (rd-skip-line)
  (let ((c (read-char)))
    (if (or (eof-object? c) (eq? c #\newline)) #f (rd-skip-line))))

(define (rd-skip-ws)
  (let ((c (peek-char)))
    (cond ((eof-object? c) #f)
          ((rd-ws? c) (read-char) (rd-skip-ws))
          ((eq? c #\;) (rd-skip-line) (rd-skip-ws))
          (else #f))))

; ---------------------------------------------------------------------------
; Tokens.  rd-token-chars accumulates characters up to the next delimiter;
; the accumulator is built in reverse and flipped once at the end.
; ---------------------------------------------------------------------------

(define (rd-token-chars acc)
  (if (rd-delim? (peek-char))
      (reverse acc)
      (rd-token-chars (cons (read-char) acc))))

; Decimal integers only -- no radix prefixes, no floats.  The accumulator is a
; host fixnum, so a literal must fit in the host's fixnum range; the dialect
; convention is to keep source literals small and build large constants with
; w32 operations at run time.
(define (rd-number neg acc)
  (if (rd-digit? (peek-char))
      (rd-number neg (+ (* acc 10) (- (char->integer (read-char)) 48)))
      (if neg (- 0 acc) acc)))

; String literals.  Only \n, \t, and "identity" escapes (\\, \") are
; recognised -- exactly what the ladder's own sources need.  92 is backslash,
; spelled via integer->char so this file never contains the escape character
; it is parsing.
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

; # syntax: #t, #f, and characters.  #\x followed by a delimiter is the
; character x itself; otherwise the whole token is a character name, of which
; only space/newline/tab are known (matched by their first letter -- the rest
; of the token is consumed but only `first` is inspected).  R5RS radix
; prefixes (#x, #b) and vectors (#(...)) are deliberately absent: sources in
; the sc1/rsc dialect must avoid them.
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

; ---------------------------------------------------------------------------
; Lists.  The subtlety is the dot: after reading `.` we peek -- a delimiter
; means it was the dotted-pair marker, anything else means the dot begins a
; symbol (this is how `...`, the syntax-rules ellipsis, reads as an ordinary
; symbol; scheme0's built-in reader cannot do this, which is why rsc.scm
; spells the ellipsis (string->symbol "...") in its own source).
; ---------------------------------------------------------------------------

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

; ---------------------------------------------------------------------------
; The entry point.  Dispatch on the first non-blank character.  Notes:
;   * eof is returned as a value (the caller's loop tests eof-object?);
;   * ' ` , ,@ expand to (quote x) etc. per R5RS 4.2.6 -- the quasiquote
;     sugar exists for rsc's benefit; sc1's own source uses none of it, so
;     sharing one reader leaves the sc1 fixpoint untouched;
;   * `-` is a number only if a digit follows; otherwise it starts a symbol
;     (so `-` and `->foo` read as identifiers).
; ---------------------------------------------------------------------------

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
