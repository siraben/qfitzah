;; Controlled fixture: (test hostheap-cliff) is a rename of
;; third_party/mes/module/mescc/preprocess.scm.  Loading it through the
;; module loader crashes qmes; dropping its last define (ast-strip-const),
;; or a few source lines, drops the run below the 512 MiB host pair-heap
;; cliff and it "passes" -- the discriminator is allocation volume, not
;; module-system semantics.  See docs/qmes-define-module-diagnosis.md.
(use-modules (test hostheap-cliff))
(display "SURVIVED\n")
