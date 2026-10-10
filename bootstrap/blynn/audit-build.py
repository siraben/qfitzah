#!/usr/bin/env python3
"""Post-build evidence checker, never a compiler input.

Exec paths supplement recipe/source review, not a sandbox: relative paths must
also be reviewed against the scripts' working-directory changes.
"""
import ast
import collections
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

HOST_TOOLS = set("bash sh env git git-upload-pack git-remote-https cat chmod cmp cp "
                 "diff dirname mkdir mktemp patch realpath rm rmdir sha256sum tar timeout "
                 "grep sed awk head tail wc sort xargs printf tr od uname ln find tee".split())
STAGE0_RELATIVE = {
    "./AMD64/artifact/" + n for n in
    "M0 M1-0 M2 blood-elf-0 catm cc_amd64 hex0 hex1 hex2-0 hex2-1 kaem-0".split()
} | {"./AMD64/bin/" + n for n in "M1 hex2 kaem".split()} | {
    "./artifact/M2", "./artifact/blood-elf-0", "./bin/M1", "./bin/blood-elf", "./bin/hex2"
}
NATIVE_RELATIVE = {"./" + n for n in
                   "tcc tcc-stage2 tcc-stage3 smoke tcc-a tcc-b tcc-c".split()}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_manifest(path, base, root):
    count = 0
    for line in path.read_text().splitlines():
        expected, name = line.split("  ", 1)
        item = (base / name).resolve()
        assert item.is_relative_to(root), ("outside build", item)
        assert digest(item) == expected, ("hash mismatch", item)
        count += 1
    assert count, ("empty manifest", path)
    return count


def check_compiler(path):
    data = path.read_bytes()
    assert data[:6] == b"\x7fELF\x02\x01", "not little-endian ELF64"
    assert struct.unpack_from("<H", data, 18)[0] == 62, "not amd64"
    offset = struct.unpack_from("<Q", data, 32)[0]
    size, count = struct.unpack_from("<HH", data, 54)
    assert size >= 4 and offset + size * count <= len(data)
    types = [struct.unpack_from("<I", data, offset + i * size)[0] for i in range(count)]
    assert 3 not in types, "host dynamic loader dependency"
    for prefix in (b"/tmp/qfitzah", b"/home/siraben", b"/nix/store/"):
        assert prefix not in data, ("embedded host prefix", prefix)


def check_static_tree(root):
    """Inspect every retained ELF executable, including intermediate compilers."""
    executables = {}
    for path in root.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            header = stream.read(64)
            if header[:4] != b"\x7fELF":
                continue
            assert len(header) == 64 and header[5] == 1, ("bad ELF header", path)
            kind = struct.unpack_from("<H", header, 16)[0]
            assert kind != 3, ("dynamic ELF artifact", path)
            if kind != 2:
                continue
            elf_class = header[4]
            assert elf_class in (1, 2), ("unknown ELF class", path)
            offset_pos, table_pos, fmt = (28, 42, "<I") if elf_class == 1 else (32, 54, "<Q")
            offset = struct.unpack_from(fmt, header, offset_pos)[0]
            size, count = struct.unpack_from("<HH", header, table_pos)
            assert size >= 4 and offset + size * count <= path.stat().st_size
            for index in range(count):
                stream.seek(offset + index * size)
                segment = struct.unpack("<I", stream.read(4))[0]
                assert segment not in (2, 3), ("dynamic loader/library segment", path)
            executables[str(path.relative_to(root))] = 32 if elf_class == 1 else 64
    assert executables, "no ELF executables found"
    return dict(sorted(executables.items()))


def check_archive(path):
    data = path.read_bytes()
    assert data[:8] == b"!<arch>\n"
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        assert header[58:] == b"`\n", ("bad archive header", path)
        assert header[16:28].strip() == b"0", ("nonzero archive date", path)
        length = int(header[48:58])
        offset += 60 + length + length % 2
    assert offset == len(data)


def check_trace(path, root):
    counts = collections.Counter()
    quoted = r'("(?:[^"\\]|\\.)*")'
    pattern = re.compile(r'\bexecve\(' + quoted)
    for line in path.read_text().splitlines():
        assert "execveat(" not in line, "execveat needs descriptor-aware manual review"
        match = pattern.search(line)
        if match:
            counts[ast.literal_eval(match[1])] += 1
    assert counts, "empty execution trace"
    relative = {}
    for name, count in counts.items():
        item = Path(name)
        if not item.is_absolute():
            assert name in STAGE0_RELATIVE | NATIVE_RELATIVE, ("unknown relative exec", name)
            relative[name] = count
        elif item.is_relative_to(root):
            assert not item.is_relative_to(root / "guard"), ("compiler fallback", name)
        else:
            assert item.name in HOST_TOOLS, ("unexpected external executable", name)
    return {"attempted_paths": dict(sorted(counts.items())),
            "relative_paths_for_recipe_review": dict(sorted(relative.items()))}


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: audit-build.py FRESH_BUILD EXEC_TRACE INDEPENDENT_FINAL_PREFIX")
    if sys.flags.optimize:
        raise SystemExit("Run without Python optimization: evidence assertions must be enabled")
    root, trace, reference = map(lambda s: Path(s).resolve(), sys.argv[1:])
    assert digest(root / "qfitzah") == "abd1975d1145c4ed808b2cac6e2265df958f1052a6b459b28664bcbcde8906aa"
    assert (root / "qfitzah").stat().st_size == 2544
    timing = json.loads((root / "timing.json").read_text())
    assert timing["complete"] and timing["fresh_recipe_pass"] and timing["exit"] == 0
    assert 0 < timing["elapsed_centiseconds"] < 1440000
    phases = [line.split("\t") for line in (root / "phases.tsv").read_text().splitlines()[1:]]
    expected = ["sources", "tools", "singularity-A", "singularity-tests-A",
                "singularity-B", "singularity-tests-B", "blynn-root", "blynn-hcc", "tcc"]
    assert [p[0] for p in phases] == expected
    assert all(p[2:] == ["passed", "0"] and int(p[1]) >= 0 for p in phases)
    assert sum(int(p[1]) for p in phases) <= timing["elapsed_centiseconds"]
    assert not (root / "tools/stage0/bootstrap-seeds").exists()
    assert not (root / "blynn-root/source/blob").exists()
    manifest_counts = {}
    for name in ("toolchain.sha256", "tools/seed.sha256", "tools/tools.sha256",
                 "blynn-root/root.sha256", "blynn-hcc/hcc.sha256", "tcc/bootstrap-tcc.sha256",
                 "tcc/tcc.sha256", "tcc/final/runtime.sha256"):
        manifest_counts[name] = check_manifest(root / name, root, root)
    manifest_counts["recipe.sha256"] = check_manifest(root / "recipe.sha256", root / "recipe", root)
    manifest_counts["fixpoints.sha256"] = check_manifest(
        root / "tcc/final/fixpoints.sha256", root / "tcc/final/source", root)
    final = root / "tcc/final"
    check_compiler(final / "bin/tcc")
    artifacts = ["bin/tcc"] + ["lib/" + p.name for p in sorted((final / "lib").iterdir())]
    for name in artifacts:
        assert (final / name).read_bytes() == (reference / name).read_bytes(), ("cross-build mismatch", name)
    for archive in (final / "lib").glob("*.a"):
        check_archive(archive)
    report = {"timing": timing, "phases": phases, "manifests_verified": manifest_counts,
              "compiler_sha256": digest(final / "bin/tcc"), "cross_build_files": artifacts,
              "static_executables": check_static_tree(root),
              "trace": check_trace(trace, root)}
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
