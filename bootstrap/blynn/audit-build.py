#!/usr/bin/env python3
"""Check completed build evidence; this program is never a compiler input.

Execution paths supplement source review, not a sandbox. Host tools are trusted
by basename. Relative executions still need working-directory review against
the recipes; neither path allowlists nor static linkage alone prove provenance.
"""
import ast
import collections
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

TIME_LIMIT_SECONDS = 1800
PHASES = ["sources", "tools", "singularity-A", "singularity-tests-A",
          "singularity-B", "singularity-tests-B", "blynn-root", "blynn-hcc", "tcc"]
HOST_TOOLS = set("bash sh env git git-upload-pack git-remote-https cat chmod cmp cp "
                 "diff dirname mkdir mktemp patch realpath rm rmdir sha256sum tar timeout "
                 "grep sed awk head tail wc sort xargs printf tr od uname ln find tee".split())
STAGE0_RELATIVE = {
    "./AMD64/artifact/" + name for name in
    "M0 M1-0 M2 blood-elf-0 catm cc_amd64 hex0 hex1 hex2-0 hex2-1 kaem-0".split()
} | {"./AMD64/bin/" + name for name in "M1 hex2 kaem".split()} | {
    "./artifact/M2", "./artifact/blood-elf-0", "./bin/M1", "./bin/blood-elf", "./bin/hex2"
}
NATIVE_RELATIVE = {"./" + name for name in
                   "tcc tcc-stage2 tcc-stage3 smoke tcc-a tcc-b tcc-c".split()}
# Do not accept an executable merely because its path is inside the build.
BUILD_PROGRAM_GROUPS = {
    "": "qfitzah",
    "tools": "qfitzah",
    "tools/stages": "scheme0.elf sc1.elf rscA.elf rscB.elf",
    "tools/hex0": "hex0",
    "tools/bin": "M2-Mesoplanet M2-Planet blood-elf M1 hex2 kaem",
    "singularity-A": "singularity",
    "singularity-B": "singularity",
    "blynn-root/bin": "vm marginally methodically crossly precisely",
    "blynn-hcc/precisely/bin": "crossly_up party party1 party2 crossly1 multiparty precisely_up",
    "blynn-hcc/objects": "materialize-object-script",
    "blynn-hcc/hcc/bin": "hcpp hcc1 hcc-m1",
    "tcc/tcc/bin": "tcc tcc-stage2 tcc-stage3",
    "tcc/final/bin": "tcc",
    "tcc/final/source": "tcc-a tcc-b tcc-c",
}
BUILD_PROGRAMS = {str(Path(directory) / name)
                  for directory, names in BUILD_PROGRAM_GROUPS.items()
                  for name in names.split()}
TEST_PROGRAM = re.compile(r"tcc/final/tmp/qfitzah-tcc-test\.[^/]+/(probe|numeric)-(a|b)")


def require(condition, message):
    """Evidence checks must remain enabled even under python -O."""
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_manifest(path, base, root):
    count = 0
    for line in path.read_text().splitlines():
        expected, name = line.split("  ", 1)
        item = (base / name).resolve()
        require(item.is_relative_to(root), f"manifest path outside build: {item}")
        require(digest(item) == expected, f"hash mismatch: {item}")
        count += 1
    require(count > 0, f"empty manifest: {path}")
    return count


def static_elf_bits(path):
    """Return 32/64 for a static x86 executable, None for non-executable data."""
    with path.open("rb") as stream:
        header = stream.read(64)
        if header[:4] != b"\x7fELF":
            return None
        require(len(header) >= 52 and header[5] == 1, f"bad ELF header: {path}")
        elf_class = header[4]
        require(elf_class in (1, 2), f"unknown ELF class: {path}")
        kind, machine = struct.unpack_from("<HH", header, 16)
        if kind == 1:  # Relocatable object, not an executable.
            return None
        require(kind == 2, f"not a static ELF executable: {path}")
        if elf_class == 1:
            bits, expected_machine, entry_size = 32, 3, 32
            offset = struct.unpack_from("<I", header, 28)[0]
            size, count = struct.unpack_from("<HH", header, 42)
        else:
            require(len(header) == 64, f"truncated ELF64 header: {path}")
            bits, expected_machine, entry_size = 64, 62, 56
            offset = struct.unpack_from("<Q", header, 32)[0]
            size, count = struct.unpack_from("<HH", header, 54)
        require(machine == expected_machine, f"unexpected machine: {path}")
        require(size == entry_size and count > 0, f"bad ELF program table: {path}")
        require(offset + size * count <= path.stat().st_size, f"truncated program table: {path}")
        segments = []
        for index in range(count):
            stream.seek(offset + index * size)
            segments.append(struct.unpack("<I", stream.read(4))[0])
        require(1 in segments, f"ELF has no load segment: {path}")
        require(not {2, 3}.intersection(segments), f"dynamic loader/library segment: {path}")
        return bits


def check_static_tree(root):
    executables = {}
    for path in root.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        bits = static_elf_bits(path)
        if bits is not None:
            executables[str(path.relative_to(root))] = bits
    require(executables, "no ELF executables found")
    return dict(sorted(executables.items()))


def check_archive(path):
    data = path.read_bytes()
    require(data[:8] == b"!<arch>\n", f"bad archive magic: {path}")
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        require(len(header) == 60 and header[58:] == b"`\n", f"bad archive header: {path}")
        require(header[16:28].strip() == b"0", f"nonzero archive date: {path}")
        length = int(header[48:58])
        require(length >= 0, f"negative archive member length: {path}")
        offset += 60 + length + length % 2
    require(offset == len(data), f"truncated archive member: {path}")


def check_trace(path, root):
    counts = collections.Counter()
    missing_host_probes = collections.Counter()
    pattern = re.compile(r'\bexecve\(("(?:[^"\\]|\\.)*")')
    for line in path.read_text().splitlines():
        require("execveat(" not in line, "execveat needs descriptor-aware manual review")
        match = pattern.search(line)
        if match:
            name = ast.literal_eval(match[1])
            counts[name] += 1
            item = Path(name)
            # env may try guard/bash before finding the real host shell.
            # Permit only failed searches for approved host tools, never an
            # executed guard or a compiler fallback (even an unsuccessful one).
            if (item.parent == root / "guard" and item.name in HOST_TOOLS
                    and line.endswith("= -1 ENOENT (No such file or directory)")):
                missing_host_probes[name] += 1
    require(counts, "empty execution trace")
    relative = {}
    for name, count in counts.items():
        item = Path(name)
        if not item.is_absolute():
            require(name in STAGE0_RELATIVE | NATIVE_RELATIVE, f"unknown relative exec: {name}")
            relative[name] = count
        elif item.is_relative_to(root):
            local = str(item.relative_to(root))
            require(local in BUILD_PROGRAMS or TEST_PROGRAM.fullmatch(local)
                    or missing_host_probes[name] == count,
                    f"unexpected build executable: {name}")
        else:
            require(item.name in HOST_TOOLS, f"unexpected external executable: {name}")
    return {"attempted_paths": dict(sorted(counts.items())),
            "missing_host_path_probes": dict(sorted(missing_host_probes.items())),
            "relative_paths_for_recipe_review": dict(sorted(relative.items()))}


def check_timing(root):
    timing = json.loads((root / "timing.json").read_text())
    require(timing["complete"] is True and timing["fresh_recipe_pass"] is True and timing["exit"] == 0,
            "build did not finish successfully")
    require(0 < timing["elapsed_centiseconds"] < TIME_LIMIT_SECONDS * 100,
            "fresh build missed the 30-minute limit")
    phases = [line.split("\t") for line in (root / "phases.tsv").read_text().splitlines()[1:]]
    require([p[0] for p in phases] == PHASES, "unexpected build phases")
    require(all(p[2:] == ["passed", "0"] and int(p[1]) >= 0 for p in phases), "failed phase")
    require(sum(int(p[1]) for p in phases) <= timing["elapsed_centiseconds"], "inconsistent timing")
    return timing, phases


def check_runtime(root, reference):
    require(not reference.is_relative_to(root), "comparison prefix must be outside the fresh build")
    final = root / "tcc/final"
    compiler = final / "bin/tcc"
    require(static_elf_bits(compiler) == 64, "final compiler is not static amd64")
    data = compiler.read_bytes()
    for prefix in (str(root).encode(), str(reference).encode(), b"/nix/store/"):
        require(prefix not in data, f"embedded build prefix: {prefix!r}")
    libraries = {"crt1.o", "crti.o", "crtn.o", "libc.a", "libgetopt.a", "libtcc1.a"}
    require({p.name for p in (final / "lib").iterdir()} == libraries, "unexpected runtime files")
    source = final / "source"
    require(data == (source / "tcc-b").read_bytes() == (source / "tcc-c").read_bytes(),
            "compiler fixpoint mismatch")
    runtime_b, runtime_c = source / "runtime-b", source / "runtime-c"
    names = {p.name for p in runtime_b.iterdir()}
    require(names and names == {p.name for p in runtime_c.iterdir()}, "runtime fixpoint files differ")
    for name in sorted(names):
        require((runtime_b / name).read_bytes() == (runtime_c / name).read_bytes(),
                f"runtime fixpoint mismatch: {name}")
    artifacts = ["bin/tcc"] + ["lib/" + name for name in sorted(libraries)]
    for name in artifacts:
        require((final / name).read_bytes() == (reference / name).read_bytes(),
                f"cross-build mismatch: {name}")
    for archive in (final / "lib").glob("*.a"):
        check_archive(archive)
    return artifacts


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: audit-build.py FRESH_BUILD EXEC_TRACE INDEPENDENT_FINAL_PREFIX")
    root, trace, reference = (Path(arg).resolve() for arg in sys.argv[1:])
    seed_hash = Path(__file__).with_name("seed.sha256").read_text().split()[0]
    require(digest(root / "qfitzah") == seed_hash, "wrong seed hash")
    require((root / "qfitzah").stat().st_size == 2544, "wrong seed size")
    timing, phases = check_timing(root)
    require(not (root / "tools/stage0/bootstrap-seeds").exists(), "imported seed directory")
    require(not (root / "blynn-root/source/blob").exists(), "imported compiler images")
    manifest_counts = {}
    for name in ("toolchain.sha256", "tools/seed.sha256", "tools/tools.sha256",
                 "blynn-root/root.sha256", "blynn-hcc/hcc.sha256", "tcc/bootstrap-tcc.sha256",
                 "tcc/tcc.sha256", "tcc/final/runtime.sha256"):
        manifest_counts[name] = check_manifest(root / name, root, root)
    manifest_counts["recipe.sha256"] = check_manifest(root / "recipe.sha256", root / "recipe", root)
    manifest_counts["fixpoints.sha256"] = check_manifest(
        root / "tcc/final/fixpoints.sha256", root / "tcc/final/source", root)
    report = {"timing": timing, "phases": phases, "manifests_verified": manifest_counts,
              "compiler_sha256": digest(root / "tcc/final/bin/tcc"),
              "cross_build_files": check_runtime(root, reference),
              "static_executables": check_static_tree(root),
              "trace": check_trace(trace, root)}
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, struct.error) as error:
        raise SystemExit(f"audit: {error}")
