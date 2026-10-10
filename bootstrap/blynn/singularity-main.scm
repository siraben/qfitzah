; Source on stdin, ION text on stdout. Validate before emitting any output.
(set! sg-port (current-input-port))
(let* ((defs (sg-program))
       (symbols (sg-symbols defs))
       (code (map (lambda (def) (sg-lower (cdr def))) defs)))
  ; The VM fills its global table sequentially: recursion uses explicit @Y,
  ; not an uninitialized forward/self table reference.
  (let validate ((rest code) (index 0))
    (if (pair? rest)
        (begin (sg-validate (car rest) symbols index)
               (validate (cdr rest) (+ index 1))) #t))
  (for-each (lambda (expr) (sg-emit expr symbols) (display ";")) code))
