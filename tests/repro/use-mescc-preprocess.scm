;; Minimal one-line repro for the host pair-heap overflow crash
;; (docs/qmes-define-module-diagnosis.md).  Under qmes this core-dumps
;; (or exits 1, layout-dependent); under bin/mes-m2 it prints SURVIVED.
;; Run via the module loader with the mescc-smoke environment, e.g.:
;;   tests/repro/run-hostheap-repro.sh ./qmes.elf tests/repro/use-mescc-preprocess.scm
(use-modules (mescc preprocess))
(display "SURVIVED\n")
