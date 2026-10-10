#!/usr/bin/env python3
"""Observer-only audit regressions; no host compiler or real build is needed."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("audit", ROOT / "bootstrap/blynn/audit-build.py")
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


def elf(bits, kind=2, segments=(1,)):
    header_size, entry_size, machine = (52, 32, 3) if bits == 32 else (64, 56, 62)
    data = bytearray(header_size + entry_size * len(segments))
    data[:6] = b"\x7fELF" + bytes((1 if bits == 32 else 2, 1))
    struct.pack_into("<HH", data, 16, kind, machine)
    if bits == 32:
        struct.pack_into("<I", data, 28, header_size)
        struct.pack_into("<HH", data, 42, entry_size, len(segments))
    else:
        struct.pack_into("<Q", data, 32, header_size)
        struct.pack_into("<HH", data, 54, entry_size, len(segments))
    for index, segment in enumerate(segments):
        struct.pack_into("<I", data, header_size + index * entry_size, segment)
    return data


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.file = self.root / "input"

    def test_elf(self):
        for bits in (32, 64):
            self.file.write_bytes(elf(bits))
            self.assertEqual(audit.static_elf_bits(self.file), bits)
            self.file.write_bytes(elf(bits, kind=1))
            self.assertIsNone(audit.static_elf_bits(self.file))
            for data in (elf(bits, kind=3), elf(bits, segments=(1, 2)),
                         elf(bits, segments=(1, 3)), elf(bits)[:-1], b"\x7fELF"):
                self.file.write_bytes(data)
                with self.subTest(bits=bits, length=len(data)):
                    with self.assertRaises(ValueError):
                        audit.static_elf_bits(self.file)

    def test_manifest(self):
        self.file.write_bytes(b"source-built output")
        manifest = self.root / "manifest"
        manifest.write_text(f"{audit.digest(self.file)}  input\n")
        self.assertEqual(audit.check_manifest(manifest, self.root, self.root), 1)
        self.file.write_bytes(b"changed output")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            audit.check_manifest(manifest, self.root, self.root)
        manifest.write_text("0  ../outside\n")
        with self.assertRaisesRegex(ValueError, "outside build"):
            audit.check_manifest(manifest, self.root, self.root)

    def test_trace(self):
        allowed = ("/usr/bin/bash", "/usr/bin/cp", str(self.root / "tools/bin/M1"), "./AMD64/bin/hex2")
        for name in allowed:
            self.file.write_text(f'execve({json.dumps(name)}, [], []) = 0\n')
            self.assertIn(name, audit.check_trace(self.file, self.root)["attempted_paths"])
        forbidden = ("/usr/bin/gcc", "./unknown", str(self.root / "guard/cc"),
                     str(self.root / "source/imported-compiler"))
        for name in forbidden:
            self.file.write_text(f'execve({json.dumps(name)}, [], []) = 0\n')
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    audit.check_trace(self.file, self.root)
        for text in ("", 'execveat(3, "compiler", [], [], 0) = 0\n'):
            self.file.write_text(text)
            with self.assertRaises(ValueError):
                audit.check_trace(self.file, self.root)

    def test_failed_host_path_search(self):
        name = str(self.root / "guard/bash")
        missing = f'execve({json.dumps(name)}, [], []) = -1 ENOENT (No such file or directory)\n'
        self.file.write_text(missing)
        self.assertEqual(audit.check_trace(self.file, self.root)["missing_host_path_probes"], {name: 1})
        # A later successful execution of the same path must still fail.
        self.file.write_text(missing + f'execve({json.dumps(name)}, [], []) = 0\n')
        with self.assertRaises(ValueError):
            audit.check_trace(self.file, self.root)
        self.file.write_text(missing.replace("guard/bash", "guard/gcc"))
        with self.assertRaises(ValueError):
            audit.check_trace(self.file, self.root)
        self.file.write_text(missing.replace("-1 ENOENT (No such file or directory)",
                                            "-1 EACCES (Permission denied)"))
        with self.assertRaises(ValueError):
            audit.check_trace(self.file, self.root)

    def test_time_limit(self):
        phases = "phase\telapsed_centiseconds\tstatus\texit\n"
        phases += "".join(f"{name}\t1\tpassed\t0\n" for name in audit.PHASES)
        (self.root / "phases.tsv").write_text(phases)
        timing = {"complete": True, "fresh_recipe_pass": True, "exit": 0,
                  "elapsed_centiseconds": 179999}
        path = self.root / "timing.json"
        path.write_text(json.dumps(timing))
        audit.check_timing(self.root)
        for change in ({"elapsed_centiseconds": 180000}, {"complete": False},
                       {"fresh_recipe_pass": False}, {"complete": "false"}, {"exit": 1}):
            path.write_text(json.dumps({**timing, **change}))
            with self.subTest(change=change):
                with self.assertRaises(ValueError):
                    audit.check_timing(self.root)

    def test_runtime_fixpoints(self):
        reference_tmp = tempfile.TemporaryDirectory()
        self.addCleanup(reference_tmp.cleanup)
        reference = Path(reference_tmp.name)
        final = self.root / "tcc/final"
        for prefix in (final, reference):
            (prefix / "bin").mkdir(parents=True)
            (prefix / "bin/tcc").write_bytes(elf(64))
            (prefix / "lib").mkdir()
            for name in ("crt1.o", "crti.o", "crtn.o", "libc.a", "libgetopt.a", "libtcc1.a"):
                (prefix / "lib" / name).write_bytes(b"!<arch>\n" if name.endswith(".a") else b"object")
        source = final / "source"
        source.mkdir()
        for suffix in ("b", "c"):
            (source / f"tcc-{suffix}").write_bytes(elf(64))
            (source / f"runtime-{suffix}").mkdir()
            (source / f"runtime-{suffix}/object.o").write_bytes(b"object")
        self.assertEqual(len(audit.check_runtime(self.root, reference)), 7)
        with self.assertRaisesRegex(ValueError, "outside"):
            audit.check_runtime(self.root, final)
        (source / "runtime-c/object.o").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "runtime fixpoint mismatch"):
            audit.check_runtime(self.root, reference)
        (source / "runtime-c/object.o").write_bytes(b"object")
        (source / "tcc-b").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "compiler fixpoint mismatch"):
            audit.check_runtime(self.root, reference)

    def test_archive(self):
        header = f"{'file/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{2:<10}`\n".encode()
        self.file.write_bytes(b"!<arch>\n" + header + b"ok")
        audit.check_archive(self.file)
        for data in (b"!<arch>\n" + header + b"o", b"not an archive",
                     b"!<arch>\n" + header[:16] + b"1" + header[17:] + b"ok"):
            self.file.write_bytes(data)
            with self.assertRaises(ValueError):
                audit.check_archive(self.file)


if __name__ == "__main__":
    unittest.main()
