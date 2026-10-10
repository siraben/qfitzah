; Assemble annotated hexadecimal source, using only the source-built runtime.
; This is a strict subset of hex0: hex digits, ASCII whitespace, #/; comments.
; Validate the entire input before opening output. No executable seed is read.
;
; FROM THE SCHEME BRANCH TO THE C-TOOLCHAIN BRANCH
; ----------------------------------------------
; rsc compiles this Scheme program to qfasm; qfitzah assembles that into an
; executable. The executable reads handwritten stage0 .hex0 SOURCE and writes
; the represented bytes. It does not copy an imported hex0 or kaem executable.
; Those newly assembled programs then build the larger stage0/M2 toolchain.
; Unlike qfasm, hex0 does not encode instructions or resolve symbolic labels:
; its source already specifies each byte as two hexadecimal digits.
;
; Read hex0-read as a two-state machine: high=#f means no pending digit;
; otherwise high holds the first half-byte, including zero (which is true in
; Scheme). Whitespace and comments leave that state unchanged. Thus "4 1"
; denotes byte 65, while an unmatched final "4" is an error, not padding.
;
; We accumulate reversed bytes and validate EOF before opening the destination.
; That costs memory proportional to this small source, but an invalid input
; cannot truncate an existing output file. The tests in tests/hex0.sh exercise
; that contract as well as every byte value, not just a self-reproducing image.
(define (hex0-digit c)
  (let ((n (char->integer c)))
    (cond ((and (>= n 48) (<= n 57)) (- n 48))
          ((and (>= n 65) (<= n 70)) (+ 10 (- n 65)))
          ((and (>= n 97) (<= n 102)) (+ 10 (- n 97)))
          (else #f))))
(define (hex0-space? c)
  (let ((n (char->integer c)))
    (or (= n 32) (and (>= n 9) (<= n 13)))))
(define (hex0-comment port)
  (let ((c (read-char port)))
    (if (or (eof-object? c) (char=? c #\newline)) #f
        (hex0-comment port))))
(define (hex0-read port)
  (let loop ((high #f) (bytes '()))
    (let ((c (read-char port)))
      (cond ((eof-object? c)
             (if high (error 'hex0 "unpaired hexadecimal digit") (reverse bytes)))
            ((or (char=? c #\#) (char=? c #\;))
             (hex0-comment port) (loop high bytes))
            ((hex0-space? c) (loop high bytes))
            (else
             (let ((digit (hex0-digit c)))
               (if (not digit) (error 'hex0 "invalid source character" c)
                   (if high (loop #f (cons (+ (* high 16) digit) bytes))
                       (loop digit bytes)))))))))
(define (hex0-write bytes port)
  (if (null? bytes) #f
      (begin (write-char (integer->char (car bytes)) port)
             (hex0-write (cdr bytes) port))))
(let ((args (cdr (command-line))))
  (if (not (= (length args) 2)) (error 'hex0 "usage: hex0 INPUT OUTPUT") #f)
  (let* ((input (open-input-file (car args)))
         (bytes (hex0-read input)))
    (close-input-port input)
    (let ((output (open-output-file (cadr args))))
      (hex0-write bytes output)
      (close-output-port output))))
