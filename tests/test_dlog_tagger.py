#!/usr/bin/env python3
"""
Tests for D-Log Tagger. Standard library only.

    python3 tests/test_dlog_tagger.py

Builds small synthetic MP4 files (no real footage) shaped like DJI Osmo Pocket 4P
clips, plus deliberately corrupt ones, then checks that:
  * the Python CLI and the Mac app label D-Log1 / D-Log2 correctly
  * neither tool crashes on corrupt files (they must report "unknown")
  * the CLI never overwrites an existing file when renaming

The Mac app is tested if it has been built (mac/build.sh) or if DLOG_APP points at
its executable; otherwise those tests are skipped.
"""
import os
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "python"))
import dlog_offload as cli  # noqa: E402

APP = os.environ.get("DLOG_APP") or os.path.join(
    ROOT, "mac", "build", "D-Log Tagger.app", "Contents", "MacOS", "DLogTagger")


# ---- building synthetic MP4 files -------------------------------------------
def box(typ, body=b""):
    return struct.pack(">I4s", 8 + len(body), typ) + body


def varint(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


def pb_varint(field, value):
    return varint(field << 3) + varint(value)


def pb_bytes(field, payload):
    return varint(field << 3 | 2) + varint(len(payload)) + payload


def djmd_frame(color_value):
    """First metadata frame, with the colour field at 2.2.3.1 like the real camera."""
    # Same nesting as a real Pocket 4P clip: 2.1.3 = "video", 2.2.1.4 = model, 2.2.3.1 = colour
    header = pb_bytes(1, pb_bytes(1, b"dvtm_osmo_pocket_4.proto"))
    camera = pb_bytes(1, pb_bytes(4, b"DJI PP-041")) + pb_bytes(3, pb_varint(1, color_value))
    stream = pb_bytes(2, pb_bytes(1, pb_bytes(3, b"video")) + pb_bytes(2, camera))
    return header + stream


def make_clip(dbcm=None, djmd=None):
    """A minimal MP4: moov (with optional dbcm tag and djmd track) followed by the frame data."""
    frame = djmd_frame(djmd) if djmd is not None else b""

    def moov(frame_offset):
        parts = b""
        if djmd is not None:
            stsd = box(b"stsd", b"\0" * 8 + box(b"djmd", b"\0" * 8))
            stsz = box(b"stsz", struct.pack(">III", 0, len(frame), 1))
            stco = box(b"stco", struct.pack(">III", 0, 1, frame_offset))
            parts += box(b"trak", box(b"mdia", box(b"hdlr", b"\0" * 8 + b"meta" + b"\0" * 12 + b"CAM meta\0")
                                      + box(b"minf", box(b"stbl", stsd + stsz + stco))))
        if dbcm is not None:
            parts += box(b"udta", box(b"dbcm", struct.pack(">I", dbcm)))
        return box(b"moov", parts)

    ftyp = box(b"ftyp", b"isom\0\0\0\0")
    head = ftyp + moov(0)
    return ftyp + moov(len(head)) + frame       # offset is stable: moov size doesn't depend on it


VALID = {
    "dlog1.MP4": (make_clip(dbcm=5, djmd=22), "DLOG1"),
    "dlog2.MP4": (make_clip(dbcm=2, djmd=2), "DLOG2"),
    "dlog1_tag_only.MP4": (make_clip(dbcm=5), "DLOG1"),
    "dlog2_track_only.MP4": (make_clip(djmd=2), "DLOG2"),
    "disagree.MP4": (make_clip(dbcm=5, djmd=2), None),       # markers disagree: never guess
    "normal_unknown_values.MP4": (make_clip(dbcm=9, djmd=99), None),
}


def corrupt_files():
    files = {}
    # 64-bit box size of 2^64-1 (crashed the app before 1.1.1)
    files["huge_size.MP4"] = box(b"ftyp", b"isom") + struct.pack(">I4sQ", 1, b"moov", 2**64 - 1) + b"\0" * 32
    # child box claiming to be far larger than its parent
    files["child_too_big.MP4"] = box(b"moov", struct.pack(">I4sQ", 1, b"udta", 2**64 - 100) + b"\0" * 16)
    # cut off in the middle of a 64-bit header (crashed the CLI before 1.1.1)
    files["truncated.MP4"] = box(b"ftyp", b"isom") + struct.pack(">I4s", 1, b"moov")
    # metadata track pointing outside the file with an absurd sample size
    stsd = box(b"stsd", b"\0" * 8 + box(b"djmd", b"\0" * 8))
    bad = box(b"trak", box(b"mdia", box(b"minf", box(b"stbl", stsd
              + box(b"stsz", struct.pack(">III", 0, 0xFFFFFFFF, 1))
              + box(b"stco", struct.pack(">III", 0, 1, 0xFFFFFFF0))))))
    files["bad_track.MP4"] = box(b"moov", bad)
    # runaway varint / bogus protobuf lengths
    clip = bytearray(make_clip(djmd=2))
    clip[-20:] = b"\x12\xff\xff\xff\xff\x0f" + b"\x80" * 14
    files["bad_protobuf.MP4"] = bytes(clip)
    # zero-size box, empty and random files
    files["zero_box.MP4"] = struct.pack(">I4s", 0, b"moov")
    files["empty.MP4"] = b""
    files["garbage.MP4"] = bytes((i * 131 + 7) % 256 for i in range(4096))
    return files


# ---- tests ------------------------------------------------------------------
class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, data):
        path = os.path.join(self.dir, name)
        with open(path, "wb") as f:
            f.write(data)
        return path


class CLIDetection(Base):
    def test_valid_clips(self):
        for name, (data, expected) in VALID.items():
            with self.subTest(name):
                self.assertEqual(cli.detect(self.write(name, data))[0], expected)

    def test_corrupt_files_never_crash(self):
        for name, data in corrupt_files().items():
            with self.subTest(name):
                self.assertIsNone(cli.detect(self.write(name, data))[0])


@unittest.skipUnless(os.access(APP, os.X_OK), f"Mac app not built ({APP})")
class AppDetection(Base):
    def run_app(self, paths):
        return subprocess.run([APP, "--detect", *paths], capture_output=True, text=True, timeout=60)

    def test_valid_clips(self):
        for name, (data, expected) in VALID.items():
            with self.subTest(name):
                r = self.run_app([self.write(name, data)])
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout.split("\t")[0], expected or "UNKNOWN")

    def test_corrupt_files_never_crash(self):
        for name, data in corrupt_files().items():
            with self.subTest(name):
                r = self.run_app([self.write(name, data)])
                self.assertEqual(r.returncode, 0, f"app crashed (exit {r.returncode}) on {name}\n{r.stderr}")
                self.assertTrue(r.stdout.startswith("UNKNOWN"), r.stdout)


class CLIRenaming(Base):
    def test_never_overwrites(self):
        src = self.write("a.MP4", b"new")
        dst = self.write("b.MP4", b"precious")
        with self.assertRaises(FileExistsError):
            cli.move_no_overwrite(src, dst)
        with open(dst, "rb") as f:
            self.assertEqual(f.read(), b"precious")
        self.assertTrue(os.path.exists(src))

    def test_renames_when_free(self):
        src = self.write("a.MP4", b"x")
        dst = os.path.join(self.dir, "c.MP4")
        cli.move_no_overwrite(src, dst)
        self.assertFalse(os.path.exists(src))
        self.assertTrue(os.path.exists(dst))

    def test_in_place_end_to_end(self):
        for name, (data, _) in VALID.items():
            self.write(name, data)
        self.write("corrupt.MP4", corrupt_files()["truncated.MP4"])
        r = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "python", "dlog_offload.py"),
                            "--in-place", self.dir], capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        names = sorted(os.listdir(self.dir))
        self.assertIn("dlog1_DLOG1.MP4", names)
        self.assertIn("dlog2_DLOG2.MP4", names)
        self.assertIn("disagree.MP4", names)          # left alone
        self.assertIn("corrupt.MP4", names)           # left alone, no crash


if __name__ == "__main__":
    unittest.main(verbosity=2)
