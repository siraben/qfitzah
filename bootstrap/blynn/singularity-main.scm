; Source on stdin, ION text on stdout. Validate before emitting any output.
;
; This is the whole compiler pipeline: parse ordered definitions, number the
; globals, eliminate lambdas, validate references, then serialize combinators.
; None of these passes executes the input program. In particular, this program
; can compile the source of another compiler without needing that compiler's
; prebuilt image. Build order is described in ../build-singularity.sh.
;
; The resulting image is not a native ELF: it runs in Blynn's VM, which the
; parallel stage0/M2 branch builds from vm.c. build-blynn-root.sh deletes the
; supplied blob directory, uses this compiler to generate singularity.ion,
; and asks that image to compile its own source inside the source-built VM.
; Byte-for-byte agreement checks the handoff; independent small programs in
; tests/singularity.sh test behavior beyond that self-reproduction property.
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
