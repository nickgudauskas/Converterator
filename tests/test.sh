#!/bin/zsh
# Runs Converterator's tests: builds sample disc images, compiles the app's code (everything in
# Sources/ except App.swift) together with tests/Tests.swift, and checks conversion, extraction, archives,
# playlists, Redump matching, CHD checks, cleanup, the library report and the updater's checks.
#
# Usage:  ./tests/test.sh             (about a minute; needs chdman)
#         ./tests/test.sh --network   (also downloads one real DAT from redump.org)
#
# Everything happens in a temporary folder that's deleted afterwards. The app's real settings,
# Application Support folder and your Trash are never touched.
set -euo pipefail
cd "${0:A:h}/.."

command -v chdman >/dev/null || { echo "chdman not found: brew install rom-tools"; exit 1; }
# The bundled tools (xdelta3 for patch tests), downloaded by build.sh into vendor/
./build.sh --fetch-only >/dev/null
XDELTA=$(ls -d "$PWD"/vendor/xdelta3-*/ | head -1); XDELTA=${XDELTA%/}
PSX="$PWD/vendor/$([[ "$(uname -m)" == arm64 ]] && echo osx-arm64 || echo osx-x64)"
DOLPHIN=$(ls -d "$PWD"/vendor/dolphin-tool-*/ | head -1); DOLPHIN=${DOLPHIN%/}
SEVENZ=$(ls -d "$PWD"/vendor/7zz-*/ | head -1); SEVENZ=${SEVENZ%/}
MAXCSO=$(ls -d "$PWD"/vendor/maxcso-*/ | head -1); MAXCSO=${MAXCSO%/}

W=$(mktemp -d "${TMPDIR:-/tmp}/converterator-tests.XXXXXX")
# The test program keeps its settings under its own name; remove them afterwards.
cleanup() {
  rm -rf "$W"
  defaults delete converterator-tests >/dev/null 2>&1 || true
  rm -f ~/Library/Preferences/converterator-tests.plist
}
trap cleanup EXIT
F="$W/fixtures"
mkdir -p "$F"/{iso/psp/PSP_GAME,iso/ps2,iso/ps1,iso/plain,cd,two,gd,chd,zip/stage/one/"Game One",zip/stage/two}
echo "Making sample discs in $W…"

rand() { head -c "$2" /dev/urandom > "$1"; }   # file, bytes
sector=2352

# ISOs: PSP, PS2 (SYSTEM.CNF with BOOT2), PS1 (BOOT), plain, and one too big for a CD (sparse)
echo UMD > "$F/iso/psp/UMD_DATA.BIN"; rand "$F/iso/psp/PSP_GAME/EBOOT.BIN" 200000
printf 'BOOT2 = cdrom0:\\SLUS_123.45;1\r\nVER = 1.00\r\n' > "$F/iso/ps2/SYSTEM.CNF"; rand "$F/iso/ps2/SLUS_123.45" 300000
printf 'BOOT = cdrom:\\SLUS_000.01;1\r\n' > "$F/iso/ps1/SYSTEM.CNF"
head -c 500000 /dev/zero > "$F/iso/plain/data.bin"
for d in psp ps2 ps1 plain; do hdiutil makehybrid -quiet -iso -o "$F/$d.iso" "$F/iso/$d"; done
dd if=/dev/zero of="$F/big.iso" bs=1 count=1 seek=1000000000 2>/dev/null

# A one-track CD
rand "$F/cd/game.bin" $((sector * 600))
printf 'FILE "game.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n' > "$F/cd/game.cue"

# A bigger one-track CD, so there's time to pause mid-file (about 190 MB, takes chdman a few seconds)
mkdir -p "$F/slow"; rand "$F/slow/slow.bin" $((sector * 80000))
printf 'FILE "slow.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n' > "$F/slow/slow.cue"

# A two-track Redump-style CD (data + audio with a gap)
rand "$F/two/Two (Track 1).bin" $((sector * 400)); rand "$F/two/Two (Track 2).bin" $((sector * 300))
printf 'FILE "Two (Track 1).bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\nFILE "Two (Track 2).bin" BINARY\n  TRACK 02 AUDIO\n    INDEX 00 00:00:00\n    INDEX 01 00:02:00\n' > "$F/two/Two.cue"

# A four-track Redump-style Dreamcast GD-ROM
for n in 1 2 3 4; do rand "$F/gd/GD (Track $n).bin" $((sector * (200 + n * 50))); done
cat > "$F/gd/GD.cue" <<'EOF'
REM SINGLE-DENSITY AREA
FILE "GD (Track 1).bin" BINARY
  TRACK 01 MODE1/2352
    INDEX 01 00:00:00
FILE "GD (Track 2).bin" BINARY
  TRACK 02 AUDIO
    INDEX 00 00:00:00
    INDEX 01 00:02:00
REM HIGH-DENSITY AREA
FILE "GD (Track 3).bin" BINARY
  TRACK 03 MODE1/2352
    INDEX 01 00:00:00
FILE "GD (Track 4).bin" BINARY
  TRACK 04 MODE1/2352
    INDEX 00 00:00:00
    INDEX 01 00:03:00
EOF

# CHDs: CD, DVD (2048-byte hunks), GD-ROM, and a damaged copy
chdman createcd -i "$F/cd/game.cue" -o "$F/chd/game.chd" >/dev/null 2>&1
chdman createdvd -hs 2048 -i "$F/ps2.iso" -o "$F/chd/ps2.chd" >/dev/null 2>&1
chdman createcd -i "$F/two/Two.cue" -o "$F/chd/two.chd" >/dev/null 2>&1
chdman createcd -i "$F/gd/GD.cue" -o "$F/chd/gd.chd" >/dev/null 2>&1
cp "$F/chd/game.chd" "$F/chd/bad.chd"
printf 'XXXXXXXX' | dd of="$F/chd/bad.chd" bs=1 seek=200000 conv=notrunc 2>/dev/null

# Archives: one game in a subfolder, two games, and zipped cartridge games
cp "$F/cd/game.cue" "$F/cd/game.bin" "$F/zip/stage/one/Game One/"
cp "$F/plain.iso" "$F/zip/stage/two/alpha.iso"; cp "$F/ps1.iso" "$F/zip/stage/two/beta.iso"
(cd "$F/zip/stage/one" && zip -qr "$F/zip/one.zip" "Game One")
(cd "$F/zip/stage/two" && zip -qr "$F/zip/two.zip" alpha.iso beta.iso)
echo cart > "$F/zip/stage/rom.sfc"; (cd "$F/zip/stage" && zip -q "$F/zip/snes.zip" rom.sfc)
# .7z (made with the bundled 7-Zip) and .rar: one game in a subfolder, and one split over three parts
(cd "$F/zip/stage/two" && "$SEVENZ/7zz" a -bd -bso0 "$F/zip/seven.7z" alpha.iso >/dev/null)
mkdir -p "$F/rar"
python3 -I tests/make_rar.py "$F/rar/one.rar" "$F/cd/game.cue=Game One/game.cue" "$F/cd/game.bin=Game One/game.bin"
python3 -I tests/make_rar.py --volumes 3 "$F/rar/Split Game" "$F/two/Two.cue=Two.cue" \
  "$F/two/Two (Track 1).bin=Two (Track 1).bin" "$F/two/Two (Track 2).bin=Two (Track 2).bin"

# ECM: a disc mixing Mode 1, Mode 2 Form 1 and Form 2 sectors (with correct EDC/ECC), damaged sectors and
# plain data, ECM-compressed: with its .cue, on its own, in a zip, and a damaged copy
mkdir -p "$F/ecm/lone" "$F/ecm/zip"
python3 -I tests/make_ecm.py sample "$F/ecm/ECM Game.bin"
python3 -I tests/make_ecm.py encode "$F/ecm/ECM Game.bin" "$F/ecm/ECM Game.bin.ecm"
printf 'FILE "ECM Game.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n' > "$F/ecm/ECM Game.cue"
cp "$F/ecm/ECM Game.bin.ecm" "$F/ecm/lone/Lone Game.bin.ecm"
(cd "$F/ecm" && zip -q "$F/ecm/zip/zipped.zip" "ECM Game.cue" "ECM Game.bin.ecm")
python3 -I -c 'import sys; d = bytearray(open(sys.argv[1], "rb").read()); d[len(d) // 2] ^= 0x40; open(sys.argv[2], "wb").write(d)' \
  "$F/ecm/ECM Game.bin.ecm" "$F/ecm/damaged.bin.ecm"

# Patches: a one-track game changed in two places (outside PPF's check block at 0x9320), made into
# xdelta, IPS, BPS and PPF patches. Plus a two-track game whose patch changes only track 2.
mkdir -p "$F/patch"
cp "$F/cd/game.bin" "$F/patch/Base.bin"
printf 'FILE "Base.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n' > "$F/patch/Base.cue"
cp "$F/patch/Base.bin" "$F/patch/target.bin"
printf 'TRANSLATED TEXT GOES HERE' | dd of="$F/patch/target.bin" bs=1 seek=5000 conv=notrunc 2>/dev/null
printf 'MORE ENGLISH' | dd of="$F/patch/target.bin" bs=1 seek=300000 conv=notrunc 2>/dev/null
"$XDELTA/xdelta3" -e -f -s "$F/patch/Base.bin" "$F/patch/target.bin" "$F/patch/Base (English).xdelta"
cp "$F/two/Two (Track 2).bin" "$F/patch/two-track2-target.bin"
printf 'NEW AUDIO?' | dd of="$F/patch/two-track2-target.bin" bs=1 seek=1000 conv=notrunc 2>/dev/null
"$XDELTA/xdelta3" -e -f -s "$F/two/Two (Track 2).bin" "$F/patch/two-track2-target.bin" "$F/patch/Two (Fixed).xdelta"
/usr/bin/python3 -I - "$F/patch/Base.bin" "$F/patch/target.bin" "$F/patch" <<'PY'
import sys, zlib, struct
src, tgt, out = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read(), sys.argv[3]
# changed ranges
ranges, i = [], 0
while i < len(tgt):
    if src[i] != tgt[i]:
        j = i
        while j < len(tgt) and src[j] != tgt[j]: j += 1
        ranges.append((i, tgt[i:j])); i = j
    else: i += 1
# IPS
ips = b"PATCH" + b"".join(struct.pack(">I", o)[1:] + struct.pack(">H", len(d)) + d for o, d in ranges) + b"EOF"
open(f"{out}/Base (IPS).ips", "wb").write(ips)
# PPF3 with the 1024-byte check block from the source
ppf = b"PPF30" + b"\x02" + b"Converterator test".ljust(50, b" ") + bytes([0, 1, 0, 0]) + src[0x9320:0x9320 + 1024]
for o, d in ranges: ppf += struct.pack("<Q", o) + bytes([len(d)]) + d
open(f"{out}/Base (PPF).ppf", "wb").write(ppf)
# BPS: copy unchanged stretches from the source, write changed ones out
def num(n):
    b = bytearray()
    while True:
        x = n & 0x7f; n >>= 7
        if n == 0: b.append(0x80 | x); break
        b.append(x); n -= 1
    return bytes(b)
body, pos = bytearray(b"BPS1" + num(len(src)) + num(len(tgt)) + num(0)), 0
for o, d in ranges:
    if o > pos: body += num(((o - pos - 1) << 2) | 0)
    body += num(((len(d) - 1) << 2) | 1) + d
    pos = o + len(d)
if pos < len(tgt): body += num(((len(tgt) - pos - 1) << 2) | 0)
body += struct.pack("<II", zlib.crc32(src), zlib.crc32(tgt))
body += struct.pack("<I", zlib.crc32(bytes(body)))
open(f"{out}/Base (BPS).bps", "wb").write(bytes(body))
PY

# Fixes to stack on top: target.bin → target2.bin, and track 1 of the two-track game
cp "$F/patch/target.bin" "$F/patch/target2.bin"
printf 'BUG FIXED' | dd of="$F/patch/target2.bin" bs=1 seek=700000 conv=notrunc 2>/dev/null
cp "$F/two/Two (Track 1).bin" "$F/patch/two-track1-target.bin"
printf 'TRACK ONE FIX' | dd of="$F/patch/two-track1-target.bin" bs=1 seek=2000 conv=notrunc 2>/dev/null
/usr/bin/python3 -I - "$F/patch" <<'PY'
import sys, struct
d = sys.argv[1]
def ips(src, tgt, out):
    s, t = open(src, "rb").read(), open(tgt, "rb").read()
    recs, i = b"", 0
    while i < len(t):
        if s[i] != t[i]:
            j = i
            while j < len(t) and s[j] != t[j]: j += 1
            recs += struct.pack(">I", i)[1:] + struct.pack(">H", j - i) + t[i:j]; i = j
        else: i += 1
    open(out, "wb").write(b"PATCH" + recs + b"EOF")
ips(f"{d}/target.bin", f"{d}/target2.bin", f"{d}/bugfix.ips")
import os
ips(os.path.join(os.path.dirname(d), "two", "Two (Track 1).bin"), f"{d}/two-track1-target.bin", f"{d}/track1fix.ips")
PY

# PlayStation discs for making PBPs: a two-disc game, disc 1 also patched, and a CHD of disc 1
mkdir -p "$F/ps1"
for d in 1 2; do /usr/bin/python3 -I tests/make_ps1_disc.py "$F/ps1/PS1 Game (Disc $d).bin" "$F/ps1/PS1 Game (Disc $d).cue" "SLUS_012.3$d" $d; done
cp "$F/ps1/PS1 Game (Disc 1).bin" "$F/ps1/patched-disc1.bin"
printf 'ENGLISH' | dd of="$F/ps1/patched-disc1.bin" bs=1 seek=200000 conv=notrunc 2>/dev/null
"$XDELTA/xdelta3" -e -f -s "$F/ps1/PS1 Game (Disc 1).bin" "$F/ps1/patched-disc1.bin" "$F/ps1/psgameenglish.xdelta"
chdman createcd -i "$F/ps1/PS1 Game (Disc 1).cue" -o "$F/ps1/PS1 Game (Disc 1).chd" >/dev/null 2>&1

# GameCube: a minimal disc image (the header's magic number is what marks it), a patched copy and its patch.
# Wii: just a header, for recognising one.
mkdir -p "$F/gc"
/usr/bin/python3 -I - "$F/gc" <<'PY'
import sys, struct
d = sys.argv[1]
data = bytearray(4 * 1024 * 1024)
data[0:6] = b"GTEST1"; data[0x1C:0x20] = struct.pack(">I", 0xC2339F3D); data[0x20:0x30] = b"Converterator GC"
for i in range(0x440, len(data), 4096): data[i:i + 8] = bytes((i // 4096 + k) & 0xFF for k in range(8))
open(f"{d}/GC Game (USA).iso", "wb").write(data)
data[0x10000:0x10007] = b"ENGLISH"
open(f"{d}/gc-patched.iso", "wb").write(data)
wii = bytearray(0x100); wii[0x18:0x1C] = struct.pack(">I", 0x5D1C9EA3)
open(f"{d}/wii-header.iso", "wb").write(wii)
PY
"$XDELTA/xdelta3" -e -f -s "$F/gc/GC Game (USA).iso" "$F/gc/gc-patched.iso" "$F/gc/gcgameenglish.xdelta"

# A Redump DAT that knows some of these
h() { shasum -a 1 "$1" | cut -c1-40; }
{
  echo '<?xml version="1.0"?><datafile><header><name>Test - Redump</name></header>'
  echo "<game name=\"Good Game (USA)\"><rom name=\"Good Game (USA).cue\" sha1=\"0000000000000000000000000000000000000000\"/><rom name=\"Good Game (USA).bin\" sha1=\"$(h "$F/cd/game.bin")\"/></game>"
  echo "<game name=\"PS2 Game (Europe)\"><rom name=\"PS2 Game (Europe).iso\" sha1=\"$(h "$F/ps2.iso")\"/></game>"
  echo "<game name=\"Two Track (Japan)\"><rom name=\"Two Track (Japan) (Track 1).bin\" sha1=\"$(h "$F/two/Two (Track 1).bin")\"/><rom name=\"Two Track (Japan) (Track 2).bin\" sha1=\"ffffffffffffffffffffffffffffffffffffffff\"/></game>"
  printf '<game name="GD Game (USA)">'
  for n in 1 2 3 4; do printf '<rom name="GD Game (USA) (Track %s).bin" sha1="%s"/>' $n "$(h "$F/gd/GD (Track $n).bin")"; done
  echo '</game>'
  for n in 1 2 3; do echo "<game name=\"Game D (USA) (Disc $n)\"><rom name=\"Game D (USA) (Disc $n).bin\" sha1=\"$(printf '%040d' $n)\"/></game>"; done
  echo '</datafile>'
} > "$F/redump.dat"
(cd "$F" && zip -q redump.zip redump.dat)

echo "Compiling…"
if ! swiftc -parse-as-library -swift-version 5 $(ls Sources/*.swift | grep -v '/App.swift$') tests/Tests.swift \
     -o "$W/converterator-tests" > "$W/compile.log" 2>&1; then
  grep -E "error" "$W/compile.log"; echo "Compiling failed."; exit 1
fi

echo "Running…"
CONVERTERATOR_DATA_DIR="$W/data" CONVERTERATOR_TOOLS_DIRS="$XDELTA:$PSX:$DOLPHIN:$SEVENZ:$MAXCSO" "$W/converterator-tests" "$F" "$W/work" "${1:-}" "$PWD"
