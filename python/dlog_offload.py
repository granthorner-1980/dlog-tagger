#!/usr/bin/env python3
"""
dlog_offload.py - copy DJI Osmo Pocket 4P clips off a card and tag each
filename with the log profile it was shot in (D-Log1 / D-Log2).

    DJI_20261108123823_0090_D.MP4  ->  DJI_20261108123823_0090_D_DLOG1.MP4

Usage
  Offload (copy + rename, card left untouched):
      python3 dlog_offload.py /Volumes/SD_CARD ~/Footage/2026-11-08

  Rename files that are already on your computer (in place):
      python3 dlog_offload.py --in-place ~/Footage/2026-11-08

  Just show what would happen:
      python3 dlog_offload.py --dry-run /Volumes/SD_CARD ~/Footage/test

How it knows
  The camera writes the color profile into every clip in two places:
    * a 'dbcm' tag in the file header (udta box)
    * a field in DJI's own metadata track ('djmd', dvtm_osmo_pocket_4.proto)
  Values were learned from sample clips. If a clip has values not in the
  tables below (e.g. a normal-color clip), it is copied with its original
  name and the raw values are printed so the tables can be extended.

Only uses the Python standard library - nothing to install.
"""
import argparse
import errno
import os
import shutil
import struct
import sys

# ---- what each raw value means (learned from real clips) -------------------
DBCM_TO_PROFILE = {5: "DLOG1", 2: "DLOG2"}
DJMD_TO_PROFILE = {22: "DLOG1", 2: "DLOG2"}

VIDEO_EXTS = {".mp4", ".mov"}
TAG_SUFFIXES = ("_DLOG1", "_DLOG2")
MAX_SAMPLE = 10_000_000      # a DJI metadata frame is a few KB; refuse anything absurd


# ---- minimal MP4 box reader -------------------------------------------------
def _boxes(f, start, end):
    pos = start
    while pos + 8 <= end:
        f.seek(pos)
        head = f.read(8)
        if len(head) < 8:
            return
        size, typ = struct.unpack(">I4s", head)
        hdr = 8
        if size == 1:
            big = f.read(8)
            if len(big) < 8:             # cut-off file
                return
            size = struct.unpack(">Q", big)[0]
            hdr = 16
        elif size == 0:
            size = end - pos
        if size < hdr or size > end - pos:   # corrupt: box doesn't fit its container
            return
        yield typ, pos, hdr, size
        pos += size


def _find(f, start, end, path):
    for typ, pos, hdr, size in _boxes(f, start, end):
        if typ == path[0]:
            if len(path) == 1:
                return pos, hdr, size
            return _find(f, pos + hdr, pos + size, path[1:])
    return None


def _read_dbcm(f, moov):
    hit = _find(f, moov[0] + moov[1], moov[0] + moov[2], [b"udta", b"dbcm"])
    if not hit:
        return None
    pos, hdr, size = hit
    f.seek(pos + hdr)
    data = f.read(size - hdr)
    return struct.unpack(">I", data[:4])[0] if len(data) >= 4 else None


# ---- minimal protobuf reader (just enough to walk DJI's metadata) ----------
def _varint(b, i):
    result = shift = 0
    while True:
        c = b[i]
        i += 1
        result |= (c & 0x7F) << shift
        shift += 7
        if c < 0x80:
            return result, i


def _pb_field(b, path):
    """Return the first varint at a nested field path like (2, 2, 3, 1)."""
    i = 0
    while i < len(b):
        key, i = _varint(b, i)
        num, wire = key >> 3, key & 7
        if wire == 0:
            val, i = _varint(b, i)
            if num == path[0] and len(path) == 1:
                return val
        elif wire == 1:
            i += 8
        elif wire == 5:
            i += 4
        elif wire == 2:
            length, i = _varint(b, i)
            chunk = b[i:i + length]
            i += length
            if num == path[0] and len(path) > 1:
                return _pb_field(chunk, path[1:])
        else:
            raise ValueError("unsupported protobuf wire type")
    return None


def _read_djmd(f, moov):
    """Read the color-profile field from the first frame of the djmd track."""
    for typ, pos, hdr, size in _boxes(f, moov[0] + moov[1], moov[0] + moov[2]):
        if typ != b"trak":
            continue
        stsd = _find(f, pos + hdr, pos + size, [b"mdia", b"minf", b"stbl", b"stsd"])
        if not stsd:
            continue
        f.seek(stsd[0] + stsd[1])
        if b"djmd" not in f.read(stsd[2] - stsd[1]):
            continue
        stbl = _find(f, pos + hdr, pos + size, [b"mdia", b"minf", b"stbl"])
        s0, s1 = stbl[0] + stbl[1], stbl[0] + stbl[2]
        stsz = _find(f, s0, s1, [b"stsz"])
        chunk, is64 = _find(f, s0, s1, [b"stco"]), False
        if not chunk:
            chunk, is64 = _find(f, s0, s1, [b"co64"]), True
        if not stsz or not chunk:
            return None
        f.seek(stsz[0] + stsz[1])
        _, sample_size, _count = struct.unpack(">III", f.read(12))
        if sample_size == 0:
            sample_size = struct.unpack(">I", f.read(4))[0]
        if not 0 < sample_size < MAX_SAMPLE:
            return None
        f.seek(chunk[0] + chunk[1] + 8)      # skip version/flags + entry count
        offset = struct.unpack(">Q" if is64 else ">I", f.read(8 if is64 else 4))[0]
        f.seek(offset)
        return _pb_field(f.read(sample_size), (2, 2, 3, 1))
    return None


def detect(path):
    """Return (profile or None, dbcm value, djmd value)."""
    corrupt = (ValueError, IndexError, struct.error)   # malformed file: treat as unknown, never crash
    with open(path, "rb") as f:
        f.seek(0, 2)
        try:
            moov = _find(f, 0, f.tell(), [b"moov"])
        except corrupt:
            moov = None
        if not moov:
            return None, None, None
        try:
            dbcm = _read_dbcm(f, moov)
        except corrupt:
            dbcm = None
        try:
            djmd = _read_djmd(f, moov)
        except corrupt:
            djmd = None
    a = DBCM_TO_PROFILE.get(dbcm)
    b = DJMD_TO_PROFILE.get(djmd)
    if a and b and a != b:
        return None, dbcm, djmd          # the two markers disagree: don't guess
    return (a or b), dbcm, djmd


# ---- naming / copying -------------------------------------------------------
def tagged_name(filename, profile):
    stem, ext = os.path.splitext(filename)
    if stem.upper().endswith(TAG_SUFFIXES):
        return filename                  # already tagged
    return f"{stem}_{profile}{ext}" if profile else filename


def find_clips(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            if name.startswith("."):
                continue                 # skip macOS ._ resource files
            if os.path.splitext(name)[1].lower() in VIDEO_EXTS:
                yield os.path.join(dirpath, name)


def move_no_overwrite(src, dst):
    """Rename src to dst, refusing (FileExistsError) if dst exists - even if it
    appears between our check and the rename."""
    if os.name == "nt":
        os.rename(src, dst)              # Windows never overwrites with rename
        return
    try:
        os.link(src, dst)                # atomic: fails if dst already exists
    except FileExistsError:
        raise
    except OSError:
        # filesystem without hard links (e.g. an exFAT SD card): best effort
        if os.path.lexists(dst):
            raise FileExistsError(errno.EEXIST, "already exists", dst)
        os.rename(src, dst)
        return
    os.unlink(src)


def copy_verified(src, dst):
    tmp = dst + ".partial"
    shutil.copy2(src, tmp)
    try:
        if os.path.getsize(tmp) != os.path.getsize(src):
            raise IOError(f"size mismatch copying {src}")
        move_no_overwrite(tmp, dst)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def main():
    ap = argparse.ArgumentParser(description="Tag DJI clips with their D-Log profile.")
    ap.add_argument("source", help="card / folder containing the clips")
    ap.add_argument("dest", nargs="?", help="folder to copy into (omit with --in-place)")
    ap.add_argument("--in-place", action="store_true", help="rename files where they are instead of copying")
    ap.add_argument("--dry-run", action="store_true", help="show what would happen, change nothing")
    args = ap.parse_args()

    if args.in_place == bool(args.dest):
        ap.error("give a destination folder, or use --in-place (not both)")
    if not os.path.isdir(args.source):
        ap.error(f"not a folder: {args.source}")
    if args.dest and not args.dry_run:
        os.makedirs(args.dest, exist_ok=True)

    counts = {"DLOG1": 0, "DLOG2": 0, "unknown": 0, "skipped": 0, "error": 0}
    for src in find_clips(args.source):
        name = os.path.basename(src)
        try:
            profile, dbcm, djmd = detect(src)
        except OSError as e:
            print(f"  ERROR    {name}: {e}")
            counts["error"] += 1
            continue

        new = tagged_name(name, profile)
        label = profile or "unknown"
        counts[label] += 1
        note = "" if profile else f"   (dbcm={dbcm}, djmd={djmd} - not a known log profile, name unchanged)"

        if args.in_place:
            dst = os.path.join(os.path.dirname(src), new)
            if dst == src:
                print(f"  {label:<8} {name}  (no change){note}")
                continue
        else:
            dst = os.path.join(args.dest, new)

        if os.path.exists(dst):
            if not args.in_place and os.path.getsize(dst) == os.path.getsize(src):
                print(f"  {label:<8} {new}  (already copied, skipped)")
                counts["skipped"] += 1
                continue
            print(f"  ERROR    {new} already exists, not overwriting")
            counts["error"] += 1
            continue

        print(f"  {label:<8} {name} -> {new}{note}")
        if args.dry_run:
            continue
        try:
            if args.in_place:
                move_no_overwrite(src, dst)
            else:
                copy_verified(src, dst)
        except FileExistsError:
            print(f"  ERROR    {new} already exists, not overwriting")
            counts["error"] += 1
        except OSError as e:
            print(f"  ERROR    {name}: {e}")
            counts["error"] += 1

    print(f"\nD-Log1: {counts['DLOG1']}   D-Log2: {counts['DLOG2']}   "
          f"other/unknown: {counts['unknown']}   already done: {counts['skipped']}   "
          f"errors: {counts['error']}" + ("   (dry run - nothing changed)" if args.dry_run else ""))
    return 1 if counts["error"] else 0


if __name__ == "__main__":
    sys.exit(main())
