"""Writes a tiny PlayStation-style disc for the tests: an ISO 9660 filesystem (with ";1" version
suffixes, as real discs have) holding SYSTEM.CNF and a boot file, stored as raw 2352-byte Mode 2
Form 1 sectors, plus a .cue. Usage: make_ps1_disc.py <out.bin> <out.cue> <game id, e.g. SLUS_012.34> [fill-byte]"""
import sys, struct, os

out_bin, out_cue, game_id = sys.argv[1], sys.argv[2], sys.argv[3]
fill = int(sys.argv[4]) if len(sys.argv) > 4 else 0
cnf = f"BOOT = cdrom:\\{game_id};1\r\nTCB = 4\r\nEVENT = 10\r\nSTACK = 801FFFF0\r\n".encode()
boot = bytes((i * 7 + fill) & 0xFF for i in range(150 * 2048))   # a 300 KB "game"

def both16(n): return struct.pack("<H", n) + struct.pack(">H", n)
def both32(n): return struct.pack("<I", n) + struct.pack(">I", n)
def date7(): return bytes([126, 1, 1, 0, 0, 0, 0])
def record(name, lba, size, is_dir=False):
    ident = name if isinstance(name, bytes) else name.encode()
    length = 33 + len(ident) + (1 - len(ident) % 2)
    r = bytes([length, 0]) + both32(lba) + both32(size) + date7() + bytes([2 if is_dir else 0, 0, 0]) + both16(1) + bytes([len(ident)]) + ident
    return r + b"\x00" * (length - len(r))

ROOT, CNF, BOOT = 20, 21, 22
files = [("SYSTEM.CNF;1", CNF, cnf), (f"{game_id};1", BOOT, boot)]
root = record(b"\x00", ROOT, 2048, True) + record(b"\x01", ROOT, 2048, True)
for name, lba, data in sorted(files):
    root += record(name, lba, len(data))
root = root.ljust(2048, b"\x00")
total = BOOT + (len(boot) + 2047) // 2048
pvd = (bytes([1]) + b"CD001" + bytes([1, 0]) + b"PLAYSTATION".ljust(32) + b"TEST".ljust(32) + b"\x00" * 8
       + both32(total) + b"\x00" * 32 + both16(1) + both16(1) + both16(2048) + both32(10)
       + struct.pack("<I", 18) + struct.pack("<I", 0) + struct.pack(">I", 19) + struct.pack(">I", 0)
       + record(b"\x00", ROOT, 2048, True)).ljust(2048, b"\x00")
term = (bytes([255]) + b"CD001" + bytes([1])).ljust(2048, b"\x00")
path_l = (bytes([1, 0]) + struct.pack("<I", ROOT) + struct.pack("<H", 1) + b"\x00\x00").ljust(2048, b"\x00")
path_m = (bytes([1, 0]) + struct.pack(">I", ROOT) + struct.pack(">H", 1) + b"\x00\x00").ljust(2048, b"\x00")
sectors = {16: pvd, 17: term, 18: path_l, 19: path_m, ROOT: root, CNF: cnf.ljust(2048, b"\x00")}
for i in range(0, len(boot), 2048):
    sectors[BOOT + i // 2048] = boot[i:i + 2048].ljust(2048, b"\x00")

def bcd(n): return ((n // 10) << 4) | (n % 10)
sync = b"\x00" + b"\xff" * 10 + b"\x00"
with open(out_bin, "wb") as f:
    for lba in range(total):
        a = lba + 150
        hdr = bytes([bcd(a // 4500), bcd((a // 75) % 60), bcd(a % 75), 2])
        f.write(sync + hdr + b"\x00\x00\x08\x00\x00\x00\x08\x00" + sectors.get(lba, b"\x00" * 2048) + b"\x00" * 280)
with open(out_cue, "w") as f:
    f.write(f'FILE "{os.path.basename(out_bin)}" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n')
