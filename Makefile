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
#   make boot-ladder    build qmes and diff Mes boot 00-14 vs the committed reference
#   make seed-from-source  rebuild build/qfitzah from qfitzah.s (binutils or nix)
#   make verify-seed    rebuild from source and cmp against the committed seed
#   make mes-reference  build bin/mes-m2 the M2-Planet way (Nix-gated)
#   make clean

SEED ?= bootstrap/seed/qfitzah

.PHONY: all check qmes boot-ladder seed-from-source verify-seed mes-reference clean

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
	done < tests/mes-reference-bootstatus.txt; \
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

clean:
	rm -rf build qmes.elf
