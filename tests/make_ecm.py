#!/usr/bin/env python3
"""Test fixtures for ECM ("Error Code Modeler") support.

  make_ecm.py sample OUT.bin          a raw CD image mixing sector kinds: Mode 1, Mode 2 Form 1 and Form 2
                                      (all with correct EDC/ECC), damaged sectors and plain data
  make_ecm.py encode IN.bin OUT.ecm   ECM-encode a raw image (sector by sector, like ecm does for a .bin)
  make_ecm.py check IN.bin [N]        how many of the first N data sectors this script's EDC/ECC reproduces
                                      exactly (to check it against a real disc)

EDC/ECC follow ECMA-130; the ECM format follows Neill Corlett's ecm/unecm.
"""
import random
import struct
import sys

# --- EDC / ECC tables -------------------------------------------------------------------------------
ECC_F = [0] * 256
ECC_B = [0] * 256
EDC = [0] * 256
for i in range(256):
    j = ((i << 1) ^ (0x11D if i & 0x80 else 0)) & 0xFF
    ECC_F[i] = j
    ECC_B[i ^ j] = i
    e = i
    for _ in range(8):
        e = (e >> 1) ^ (0xD8018001 if e & 1 else 0)
    EDC[i] = e


def edc(data, crc=0):
    for b in data:
        crc = (crc >> 8) ^ EDC[(crc ^ b) & 0xFF]
    return crc


def ecc_block(s, major_count, minor_count, major_mult, minor_inc, dest):
    src = s[0xC:0xC + major_count * minor_count]   # (a copy: Q covers P, which is written first)
    size = major_count * minor_count
    for major in range(major_count):
        index = (major >> 1) * major_mult + (major & 1)
        a = b = 0
        for _ in range(minor_count):
            t = src[index]
            index += minor_inc
            if index >= size:
                index -= size
            a ^= t
            b ^= t
            a = ECC_F[a]
        a = ECC_B[ECC_F[a] ^ b]
        s[dest + major] = a
        s[dest + major + major_count] = a ^ b


def ecc(s, zero_address):
    saved = s[12:16]
    if zero_address:
        s[12:16] = b"\0\0\0\0"
    ecc_block(s, 86, 24, 2, 86, 0x81C)
    ecc_block(s, 52, 43, 86, 88, 0x8C8)
    if zero_address:
        s[12:16] = saved


def regenerate(s, kind):
    """Fills in the EDC/ECC of a 2352-byte sector: kind 1 = Mode 1, 2 = Mode 2 Form 1, 3 = Mode 2 Form 2."""
    if kind == 1:
        s[0x810:0x814] = struct.pack("<I", edc(s[0:0x810]))
        s[0x814:0x81C] = bytes(8)
        ecc(s, False)
    elif kind == 2:
        s[0x818:0x81C] = struct.pack("<I", edc(s[0x10:0x818]))
        ecc(s, True)
    else:
        s[0x92C:0x930] = struct.pack("<I", edc(s[0x10:0x92C]))


SYNC = b"\x00" + b"\xff" * 10 + b"\x00"


def kind_of(s):
    """1, 2 or 3 if this sector is exactly what that kind regenerates to, else 0."""
    if s[:12] != SYNC:
        return 0
    if s[15] == 1:
        t = bytearray(s); regenerate(t, 1)
        return 1 if t == s else 0
    if s[15] == 2 and s[0x10:0x14] == s[0x14:0x18]:
        for k in (2, 3):
            t = bytearray(s); regenerate(t, k)
            if t == s:
                return k
    return 0


def bcd(n):
    return (n // 10) * 16 + n % 10


def header(lba, mode):
    lba += 150
    return SYNC + bytes([bcd(lba // 4500), bcd(lba // 75 % 60), bcd(lba % 75), mode])


def sample(path):
    rnd = random.Random(1234)
    out = bytearray()
    plan = ["m1"] * 40 + ["f1"] * 60 + ["f2"] * 30 + ["bad"] * 3 + ["m1"] * 10 + ["raw"] * 5 + ["f1"] * 20
    for lba, what in enumerate(plan):
        if what == "raw":   # e.g. audio
            out += bytes(rnd.getrandbits(8) for _ in range(2352))
            continue
        s = bytearray(2352)
        if what in ("m1", "bad"):
            s[0:16] = header(lba, 1)
            s[0x10:0x810] = bytes(rnd.getrandbits(8) for _ in range(0x800)) if lba % 3 else bytes(0x800)
            regenerate(s, 1)
            if what == "bad":
                s[0x900] ^= 0x55   # damaged ECC: has to be kept as it is
        else:
            s[0:16] = header(lba, 2)
            sub = bytes([0, 0, 0x08 if what == "f1" else 0x20, 0])
            s[0x10:0x14] = sub; s[0x14:0x18] = sub
            n = 0x800 if what == "f1" else 0x914
            s[0x18:0x18 + n] = bytes(rnd.getrandbits(8) for _ in range(n))
            regenerate(s, 2 if what == "f1" else 3)
        out += s
    open(path, "wb").write(out)


def put_count(out, kind, count):
    n = count - 1
    out.append(((n & 0x1F) << 2) | kind | (0x80 if n >> 5 else 0))
    n >>= 5
    while n:
        out.append((n & 0x7F) | (0x80 if n >> 7 else 0))
        n >>= 7


def encode(src, dst):
    data = open(src, "rb").read()
    records = []   # (kind, payload): kind 0 = literal bytes
    def literal(b):
        if records and records[-1][0] == 0:
            records[-1] = (0, records[-1][1] + b)
        else:
            records.append((0, b))
    pos = 0
    while pos + 2352 <= len(data):
        s = data[pos:pos + 2352]
        k = kind_of(s)
        if k == 1:
            records.append((1, s[0xC:0xF] + s[0x10:0x810]))
        elif k == 2:
            literal(s[:16]); records.append((2, s[0x14:0x14 + 0x804]))
        elif k == 3:
            literal(s[:16]); records.append((3, s[0x14:0x14 + 0x918]))
        else:
            literal(s)
        pos += 2352
    if pos < len(data):
        literal(data[pos:])
    out = bytearray(b"ECM\0")
    i = 0
    while i < len(records):
        kind, payload = records[i]
        if kind == 0:
            put_count(out, 0, len(payload)); out += payload; i += 1
            continue
        j = i
        while j < len(records) and records[j][0] == kind:
            j += 1
        put_count(out, kind, j - i)
        for _, p in records[i:j]:
            out += p
        i = j
    # End marker (a count of 0xFFFFFFFF + 1), then the EDC of the whole decoded image.
    out.append(0xFC); out += bytes([0xFF, 0xFF, 0xFF, 0x3F])
    out += struct.pack("<I", edc(data))
    open(dst, "wb").write(out)


def check(path, limit):
    data = open(path, "rb").read(2352 * limit)
    counts = {0: 0, 1: 0, 2: 0, 3: 0}
    for pos in range(0, len(data) - 2351, 2352):
        counts[kind_of(data[pos:pos + 2352])] += 1
    print("sectors reproduced: mode1 %d, form1 %d, form2 %d; not reproduced %d" % (counts[1], counts[2], counts[3], counts[0]))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "sample":
        sample(sys.argv[2])
    elif cmd == "encode":
        encode(sys.argv[2], sys.argv[3])
    elif cmd == "check":
        check(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 2000)
