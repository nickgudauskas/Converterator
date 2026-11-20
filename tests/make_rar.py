#!/usr/bin/env python3
"""Writes RAR 5 test archives without the rar program (files are stored, not compressed).

  make_rar.py OUT.rar FILE[=NAME-IN-ARCHIVE]...                 one archive
  make_rar.py --volumes N OUT_BASE FILE[=NAME-IN-ARCHIVE]...    OUT_BASE.part1.rar … partN.rar, with the
                                                                files' data split across the parts

Follows RARLAB's RAR 5.0 archive format description (https://www.rarlab.com/technote.htm).
"""
import struct
import sys
import zlib

SIGNATURE = b"Rar!\x1a\x07\x01\x00"


def vint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def block(fields):
    """A header block: CRC32, size, then the fields (type, flags, …)."""
    size = vint(len(fields))
    return struct.pack("<I", zlib.crc32(size + fields)) + size + fields


def main_header(volume=False, number=0):
    flags = (0x0001 if volume else 0) | (0x0002 if number else 0)
    return block(vint(1) + vint(0) + vint(flags) + (vint(number) if number else b""))


def file_header(name, part, total_size, crc=None, before=False, after=False):
    hflags = 0x0002 | (0x0008 if before else 0) | (0x0010 if after else 0)   # data area; split before/after
    fflags = 0x0004 if crc is not None else 0                                # CRC32 present
    name = name.encode("utf-8")
    fields = (vint(2) + vint(hflags) + vint(len(part)) + vint(fflags) + vint(total_size) + vint(0x20)
              + (struct.pack("<I", crc) if crc is not None else b"")
              + vint(0)            # compression: version 0, stored
              + vint(0)            # host OS: Windows
              + vint(len(name)) + name)
    return block(fields) + part


def end_header(more_volumes=False):
    return block(vint(5) + vint(0) + vint(0x0001 if more_volumes else 0))


def parse_files(args):
    files = []
    for a in args:
        path, _, name = a.partition("=")
        files.append((name or path.rsplit("/", 1)[-1], open(path, "rb").read()))
    return files


def single(out, files):
    body = SIGNATURE + main_header()
    for name, data in files:
        body += file_header(name, data, len(data), zlib.crc32(data))
    open(out, "wb").write(body + end_header())


def volumes(n, base, files):
    # The file data, cut into n roughly equal parts; a file crossing a cut is split between parts.
    cut = -(-sum(len(d) for _, d in files) // n)
    vols = [bytearray(SIGNATURE + main_header(True, i)) for i in range(n)]
    v, used = 0, 0
    for name, data in files:
        start = 0
        while start < len(data):
            room = cut - used if v < n - 1 else len(data) - start
            if room <= 0:
                v, used = v + 1, 0
                continue
            take = min(room, len(data) - start)
            before, after = start > 0, start + take < len(data)
            # Whole files carry their CRC; split ones leave it out (it's optional).
            crc = zlib.crc32(data) if not (before or after) else None
            vols[v] += file_header(name, data[start:start + take], len(data), crc, before, after)
            start += take; used += take
    for i, vol in enumerate(vols):
        open("%s.part%d.rar" % (base, i + 1), "wb").write(bytes(vol) + end_header(i < n - 1))


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[0] == "--volumes":
        volumes(int(a[1]), a[2], parse_files(a[3:]))
    else:
        single(a[0], parse_files(a[1:]))
