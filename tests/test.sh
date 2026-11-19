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
CONVERTERATOR_DATA_DIR="$W/data" "$W/converterator-tests" "$F" "$W/work" "${1:-}" "$PWD"
