# Qfitzah — portable entry points, buildable with or without Nix.
#
# The trusted root is the ~1.7 KiB seed. bootstrap/seed/qfitzah is a committed,
# hand-auditable prebuilt of it (source: qfitzah.s), so the whole ladder — up to
# the qmes Mes interpreter — runs on any i386-capable Linux with only sh + cat,
# no toolchain. `make verify-seed` reproduces the seed from qfitzah.s (via host
# binutils, else Nix) and byte-compares it against the committed copy.
#
# Targets:
#   make check          run the full test suite with the committed seed
#   make qmes           build qmes.elf (seed -> qfasm -> scheme0 -> sc1 -> rsc -> qmes)
#   make qmes64         build qmes64.elf (the x86_64-output variant, qmes.scm +
#                       qmes-w64.scm overlay)
#   make boot-ladder    build qmes and diff Mes boot 00-14 vs the committed reference
#   make seed-from-source  rebuild build/qfitzah from qfitzah.s (binutils or nix)
#   make verify-seed    rebuild from source and cmp against the committed seed
#   make mes-reference  build bin/mes-m2 the M2-Planet way (Nix-gated)
#   make fixpoint       F1: MesCC -S over all 20 mes_SOURCES under qmes vs
#                       bin/mes-m2, byte-compared per unit (needs bin/mes-m2)
#   make fixpoint-verify  offline F1 gate: qmes sweep vs committed hashes
#                       (needs only qmes.elf + vendored nyacc; no M2-Planet)
#   make fixpoint-64    the x86_64 fixpoint (F1-64/F2-64/F3-64): qmes64 vs
#                       bin/mes-m2-64 (needs bin/mes-m2-64; Nix-gated)
#   make tcc-reference  T0: build the reference TinyCC under bin/mes-m2 and
#                       commit its .s + binary hashes (Nix-gated)
#   make tcc            T1+T2+T3: qmes compiles the full TinyCC byte-identically
#                       to bin/mes-m2, links + self-hosts (needs bin/mes-m2)
#   make tcc-verify     offline T1 gate: qmes tcc sweep vs committed hashes
#   make regen          regenerate every committed generated artifact in place
#                       from its in-dialect generator bootstrap/gen-*.scm (then
#                       `make regen-verify` re-pins the bytes)
#   make regen-verify   prove every committed generated artifact (qfasm.qf1,
#                       scheme0.qfasm, the *-runtime files, the qfasm-* test
#                       fixtures) is reproduced BYTE-IDENTICALLY by its
#                       in-dialect generator bootstrap/gen-*.scm (the zero-Python
#                       replacements for the retired tools/generate_*.py)
#   make clean

SEED ?= bootstrap/seed/qfitzah

.PHONY: all check qmes qmes64 boot-ladder seed-from-source verify-seed mes-reference fixpoint fixpoint-verify fixpoint-64 regen regen-verify tcc-reference tcc tcc-verify clean

all: qmes

check: $(SEED)
	tests/run.sh $(SEED)

qmes: $(SEED)
	tools/build-qmes.sh $(SEED)

boot-ladder: qmes
	@pfx=$$PWD/third_party/mes; fail=0; \
	while read line; do \
	  t=$${line%% *}; want=$${line##*> }; \
	  MES_BOOT=$$pfx/scaffold/boot/$$t.scm MES_PREFIX=$$pfx ./qmes.elf >/dev/null 2>&1; got=$$?; \
	  if [ "$$got" = "$$want" ]; then echo "ok   $$t -> $$got"; \
	  else echo "FAIL $$t -> $$got (want $$want)"; fail=1; fi; \
	done < tests/references/bootstatus.txt; \
	[ $$fail = 0 ] && echo "boot-ladder: qmes matches the reference"

# Rebuild the seed from qfitzah.s: prefer host binutils, else Nix.
seed-from-source:
	@mkdir -p build
	@if command -v as >/dev/null 2>&1 && command -v ld >/dev/null 2>&1 && command -v objcopy >/dev/null 2>&1; then \
	  set -e; \
	  as --32 qfitzah.s -o build/qfitzah.o; \
	  ld -m elf_i386 -static -z noseparate-code -o build/qfitzah.bloated build/qfitzah.o; \
	  objcopy -S -R .note.gnu.build-id -R .note.gnu.property build/qfitzah.bloated build/qfitzah; \
	  echo "seed-from-source: built build/qfitzah with binutils"; \
	elif command -v nix >/dev/null 2>&1; then \
	  nix build .#qfitzah --out-link build/seed-result; \
	  cp -f build/seed-result/bin/qfitzah build/qfitzah; chmod +w build/qfitzah; \
	  echo "seed-from-source: built build/qfitzah with nix"; \
	else \
	  echo "seed-from-source: need binutils (as/ld/objcopy) or nix; the committed seed at $(SEED) is ready to use as-is"; \
	  exit 1; \
	fi

verify-seed: seed-from-source
	@cmp build/qfitzah $(SEED) \
	  && echo "verify-seed: committed seed is byte-identical to a fresh build of qfitzah.s" \
	  || { echo "verify-seed: MISMATCH — committed seed differs from qfitzah.s"; exit 1; }

mes-reference:
	tools/build-mes-reference.sh

# The working fixpoint on i386: F1 (path-independent MesCC assembly over all
# 20 mes_SOURCES under qmes vs bin/mes-m2), F2 (byte-identical mescc-linked mes
# binary from each path), F3 (self-recompilation hosted on the qmes-path binary).
# Needs bin/mes-m2 (make mes-reference) + mescc-tools (self-enters nix shell).
# The qmes F1 sweep is interpreted and slow (~16 min).  Pass JOBS=N to tune.
fixpoint: qmes
	tools/fixpoint.sh

# Offline F1 gate: run only the qmes sweep and check it against the committed
# reference hashes.  No M2-Planet / mes-m2 / mescc-tools needed.
fixpoint-verify: qmes
	tools/mescc-fixpoint.sh verify $(if $(JOBS),$(JOBS),16)

# Regenerate every committed generated artifact in place from its in-dialect
# generator bootstrap/gen-*.scm (run `make regen-verify` afterwards to re-pin).
# Depends on qmes (builds the rsc toolchain the generators run on).
regen: qmes
	tools/regen.sh gen qfasm            > bootstrap/qfasm.qf1
	tools/regen.sh gen scheme0          > bootstrap/scheme0.qfasm
	tools/regen.sh gen sc1-runtime      > bootstrap/sc1-runtime.qf1
	tools/regen.sh gen sc1-runtime --flat > bootstrap/sc1-asm-runtime.flat
	tools/regen.sh gen rsc-runtime      > bootstrap/rsc-runtime.qf1
	tools/regen.sh gen rsc-runtime --flat > bootstrap/asm-runtime.flat
	tools/regen.sh gen qfasm-tests exit42-qfasm  > tests/cases/qfasm-exit42.qfasm
	tools/regen.sh gen qfasm-tests exit42-hex    > tests/cases/qfasm-exit42.hex
	tools/regen.sh gen qfasm-tests exit42-status > tests/cases/qfasm-exit42.status
	tools/regen.sh gen qfasm-tests arith-qfasm   > tests/cases/qfasm-arith.qfasm
	tools/regen.sh gen qfasm-tests arith-out     > tests/cases/qfasm-arith.out
	tools/regen.sh gen qfasm-tests big-qfasm     > tests/cases/qfasm-big.qfasm
	tools/regen.sh gen qfasm-tests big-hex       > tests/cases/qfasm-big.hex
	tools/regen.sh gen qfasm-tests big-status    > tests/cases/qfasm-big.status
	@echo "regen: regenerated committed artifacts (run 'make regen-verify' to confirm)"

# Prove the in-dialect generators reproduce every committed generated artifact
# byte-for-byte.  Depends on qmes (builds the rsc toolchain the generators run on).
regen-verify: qmes
	tools/regen-verify.sh

# The next bootstrap rung: qmes's MesCC compiles the full TinyCC byte-identically
# to the bin/mes-m2 MesCC path (docs/mes-bootstrap.md).
#
#   tcc-reference  T0: build the reference tcc under bin/mes-m2 (10-unit sweep,
#                  libc+tcc, link tcc-mes.ref, stage, hello exit 42, self-host
#                  boot chain, cmp boot5==boot6) and commit the .s + binary
#                  hashes to tests/references/mescc/tcc/t0.sha256.  Nix-gated
#                  (mescc-tools + bin/mes-m2), like mes-reference.
#   tcc            T1+T2+T3: qmes compiles the same 10 units, cmp each against
#                  the reference, link tcc-mes.qmes and cmp the binary, then the
#                  qmes-built tcc self-hosts.  Interpreted qmes sweep is slow
#                  (~30-60 min at parallel).  Pass JOBS=N to tune.
#   tcc-verify     Offline T1 gate: qmes-only 10-unit sweep vs the committed .s
#                  hashes (needs only qmes.elf + vendored nyacc/tinycc).
tcc-reference:
	tools/build-tcc.sh t0 $(if $(JOBS),$(JOBS),16)

tcc: qmes
	tools/build-tcc.sh fixpoint $(if $(JOBS),$(JOBS),16)

tcc-verify: qmes
	tools/build-tcc.sh verify $(if $(JOBS),$(JOBS),8)

# Build the 64-bit qmes variant (qmes.scm + qmes-w64.scm overlay).
qmes64: $(SEED)
	tools/build-qmes64.sh $(SEED)

# The x86_64 fixpoint: F1-64/F2-64/F3-64 of MesCC targeting x86_64, qmes64
# vs bin/mes-m2-64.  Needs bin/mes-m2-64 (ARCH=x86_64 make mes-reference) +
# mescc-tools amd64 (self-enters nix shell).  Slow (interpreted + w64 in Scheme).
fixpoint-64: qmes64
	tools/fixpoint-64.sh

clean:
	rm -rf build qmes.elf qmes64.elf
