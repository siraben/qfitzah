(define-module (test hostheap-cliff)
  #:use-module (ice-9 optargs)
  #:use-module (system base pmatch)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (nyacc lang c99 parser)
  #:use-module (nyacc version)
  #:use-module (mes guile)
  #:use-module (mes misc))

(define mes-or-reproducible? #t)

(when (getenv "MESC_DEBUG")
  (format (current-error-port) "*nyacc-version*=~a\n" *nyacc-version*))

;; list of which rules you want progress reported
(define need-progress
  (or (assoc-ref
       '(("0.85.3" (1 2 3))
         ("0.86.0" (1 2 3)))
       *nyacc-version*)
      '((1 2 3))))

(define (progress o)
  (when (and o (getenv "NYACC_DEBUG"))
    (display "    :" (current-error-port))
    (display o (current-error-port))
    (display "\n" (current-error-port))))

(define (insert-progress-monitors act-v len-v)
  (let ((n (vector-length act-v)))
    (let loop ((ix 0))
      (when (< ix n)
	(if (memq ix need-progress)
	    (vector-set!
	     act-v ix
	     (lambda args
	       (progress (list-ref args (1- (vector-ref len-v ix))))
	       (apply (vector-ref act-v ix) args))))
        (loop (1+ ix))))))

(insert-progress-monitors (@@ (nyacc lang c99 parser) c99-act-v)
                          (@@ (nyacc lang c99 parser) c99-len-v))


(define* (c99-input->full-ast #:key (prefix "") (defines '()) (includes '()) (arch "") verbose?)
  (let* ((sys-include (if (equal? prefix "") "include"
                          (string-append prefix "/include")))
         (kernel "linux")
         (kernel-include (string-append sys-include "/" kernel "/" arch))
         (includes (append
                    includes
                    (cons* kernel-include
                           sys-include
                           (append (or (and=> (getenv "CPATH")
                                              (cut string-split <> #\:)) '())
                                   (or (and=> (getenv "C_INCLUDE_PATH")
                                              (cut string-split <> #\:)) '())))))
         (defines `(
                    "NULL=0"
                    "__linux__=1"
                    "_POSIX_SOURCE=0"
                    "SYSTEM_LIBC=0"
                    "__STDC__=1"
                    "__MESC__=1"
                    ,(if mes-or-reproducible? "__MESC_MES__=1" "__MESC_MES__=0")
                    ,@defines)))
    (when (and verbose? (> verbose? 1))
      (format (current-error-port) "includes: ~s\n" includes)
      (format (current-error-port) "defines: ~s\n" defines))
    (parse-c99
     #:inc-dirs includes
     #:cpp-defs defines
     #:mode 'code)))

(define* (c99-input->ast #:key (prefix "") (defines '()) (includes '()) (arch "") verbose?)
  (when verbose?
    (format (current-error-port) "parsing: input\n"))
  ((compose ast-strip-inline
            ast-strip-attributes
            ast-strip-const
            ast-strip-comment)
   (c99-input->full-ast #:prefix prefix #:defines defines #:includes includes #:arch arch #:verbose? verbose?)))

(define (ast-strip-comment o)
  (pmatch o
    ((@ (comment . ,comment)) #f) ; Nyacc 0.90.2/0.93.0?
    ((comment . ,comment) #f)
    (((comment . ,comment) . ,t) (filter-map ast-strip-comment t))
    (((comment . ,comment) . ,tail) tail)
    ((,head . (comment . ,comment)) head)
    ((,h . ,t) (if (list? o) (filter-map ast-strip-comment o)
                   (cons (ast-strip-comment h) (ast-strip-comment t))))
    (_  o)))

(define (qual-const? qual)
  (or (equal? qual "const")             ;Nyacc <  1.04.0
      (equal? qual '(const))))          ;Nyacc >= 1.04.0


(define (ast-strip-attributes o)
  (pmatch o
    ((decl-spec-list (@ (attributes . ,attributes)) . ,rest)
     `(decl-spec-list ,@rest))
    ((,h . ,t) (if (list? o) (filter-map ast-strip-attributes o)
                   (cons (ast-strip-attributes h) (ast-strip-attributes t))))
    (_  o)))

(define (ast-strip-inline o)
  (pmatch o
    ((decl-spec-list (fctn-spec ,spec) . ,rest) (guard (equal? spec "inline"))
     `(decl-spec-list ,@rest))
    ((decl-spec-list (stor-spec (static)) (fctn-spec ,spec) . ,rest)
     (guard (equal? spec "inline"))
     `(decl-spec-list (stor-spec (static)) ,@rest))
    ((,h . ,t) (if (list? o) (filter-map ast-strip-inline o)
                   (cons (ast-strip-inline h) (ast-strip-inline t))))
    (_  o)))

(define (ast-strip-const o)
  (pmatch o
    ((type-qual ,qual) (if (qual-const? qual) #f o))
    ((pointer (type-qual-list (type-qual ,qual)) . ,rest)
     (if (qual-const? qual) `(pointer ,@rest) o))
    ((decl-spec-list (type-qual ,qual))
     (if (qual-const? qual) #f
         `(decl-spec-list (type-qual ,qual))))
    ((decl-spec-list (type-qual ,qual) . ,rest)
     (if (qual-const? qual) `(decl-spec-list ,@rest)
         `(decl-spec-list (type-qual ,qual) ,@(map ast-strip-const rest))))
    ((decl-spec-list (type-qual-list (type-qual ,qual)) . ,rest)
     (if (qual-const? qual) `(decl-spec-list ,@rest)
         `(decl-spec-list (type-qual-list (type-qual ,qual)) ,@(map ast-strip-const rest))))
    ((,h . ,t) (if (list? o) (filter-map ast-strip-const o)
                   (cons (ast-strip-const h) (ast-strip-const t))))
    (_  o)))
