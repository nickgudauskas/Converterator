#!/bin/zsh
# Builds "Converterator.app" next to this script.
# Ad-hoc signed by default. Set SIGN_IDENTITY (e.g. "Developer ID Application") to sign for
# distribution; notarize.sh does that for you.
# ./build.sh --fetch-only downloads the bundled tools into vendor/ and stops (the GitHub tests use this).
set -euo pipefail
cd "${0:A:h}"

APP="Converterator.app"
PSX_VERSION="v1.8.0"
# chdman, built from MAME's source by .github/workflows/chdman.yml and published as a release of this repo.
CHDMAN_VERSION="0.289"
CHDMAN_SHA256="7a46959ffe42669e844348449b00e4fd09c268750e3f64939d0af951acf82cf7"
# xdelta3, for applying xdelta patches: the project's own dependency-free macOS builds (Apache 2.0).
XDELTA_VERSION="3.2.2"
XDELTA_SHA256_ARM64="27dcf763beb075ed28061ef136613f4bc6ea3999cb424f23a7d59f18ca2d7c8b"
XDELTA_SHA256_X86_64="e217f4d0f92357ee890f9d8b5571f7eb836a86ff87e8834bed0b9d9b38630f86"

# PSXPackager isn't stored in this repo; fetch both macOS release builds once into vendor/.
# It's a .NET single-file app, which can't be merged with lipo, so the app carries one per CPU.
fetch_psx() {   # $1 = release platform (osx-arm64 / osx-x64)
  if [[ ! -x "vendor/$1/psxpackager" ]]; then
    echo "Downloading PSXPackager $PSX_VERSION ($1)…"
    mkdir -p vendor
    curl -fsSL -o "vendor/$1.tar.gz" \
      "https://github.com/RupertAvery/PSXPackager/releases/download/$PSX_VERSION/psxpackager-$1.tar.gz"
    tar -xzf "vendor/$1.tar.gz" -C vendor
    rm -rf "vendor/$1"
    mv "vendor/psxpackager-$1" "vendor/$1"
    rm -f "vendor/$1.tar.gz"
  fi
}
fetch_psx osx-arm64
fetch_psx osx-x64
# PSXPackager is MIT-licensed; its license must travel with the copy bundled in the app.
if [[ ! -f vendor/LICENSE-psxpackager ]]; then
  curl -fsSL -o vendor/LICENSE-psxpackager \
    "https://raw.githubusercontent.com/RupertAvery/PSXPackager/$PSX_VERSION/LICENSE"
fi

# chdman: download the universal build once into vendor/, and check it's exactly the one published.
if [[ ! -x "vendor/chdman-$CHDMAN_VERSION/chdman" ]]; then
  echo "Downloading chdman $CHDMAN_VERSION…"
  mkdir -p vendor
  curl -fsSL -o "vendor/chdman-$CHDMAN_VERSION.zip" \
    "https://github.com/nickgudauskas/Converterator/releases/download/chdman-$CHDMAN_VERSION/chdman-universal.zip"
  if [[ "$(shasum -a 256 "vendor/chdman-$CHDMAN_VERSION.zip" | cut -d' ' -f1)" != "$CHDMAN_SHA256" ]]; then
    echo "chdman download doesn't match the expected SHA-256"; rm -f "vendor/chdman-$CHDMAN_VERSION.zip"; exit 1
  fi
  rm -rf "vendor/chdman-$CHDMAN_VERSION"
  ditto -x -k "vendor/chdman-$CHDMAN_VERSION.zip" "vendor/chdman-$CHDMAN_VERSION"
  rm -f "vendor/chdman-$CHDMAN_VERSION.zip"
fi

# xdelta3: both official macOS builds, checked against their SHA-256s, merged into one universal program.
XD="vendor/xdelta3-$XDELTA_VERSION"
if [[ ! -x "$XD/xdelta3" ]]; then
  echo "Downloading xdelta3 $XDELTA_VERSION…"
  rm -rf "$XD"; mkdir -p "$XD/download"
  for pair in "arm64:$XDELTA_SHA256_ARM64" "x86_64:$XDELTA_SHA256_X86_64"; do
    arch=${pair%%:*} sha=${pair#*:}
    tgz="$XD/download/xdelta3-$arch.tar.gz"
    curl -fsSL -o "$tgz" "https://github.com/jmacd/xdelta/releases/download/v$XDELTA_VERSION/xdelta3-$XDELTA_VERSION-macos-$arch.tar.gz"
    [[ "$(shasum -a 256 "$tgz" | cut -d' ' -f1)" == "$sha" ]] || { echo "xdelta3 ($arch) doesn't match the expected SHA-256"; rm -rf "$XD"; exit 1; }
    tar -xzf "$tgz" -C "$XD/download"
  done
  lipo -create "$XD/download/xdelta3-$XDELTA_VERSION-macos-arm64/xdelta3" "$XD/download/xdelta3-$XDELTA_VERSION-macos-x86_64/xdelta3" -output "$XD/xdelta3"
  curl -fsSL -o "$XD/LICENSE" "https://raw.githubusercontent.com/jmacd/xdelta/v$XDELTA_VERSION/xdelta3/LICENSE"
  printf 'xdelta3 %s (https://github.com/jmacd/xdelta), the official macOS builds for Apple Silicon and Intel\nfrom https://github.com/jmacd/xdelta/releases/tag/v%s, combined with lipo. Apache License 2.0 (see LICENSE).\n' \
    "$XDELTA_VERSION" "$XDELTA_VERSION" > "$XD/SOURCE.txt"
  rm -rf "$XD/download"
fi

[[ "${1:-}" == "--fetch-only" ]] && { echo "Tools are in vendor/."; exit 0; }

rm -rf "$APP" build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources/psxpackager"

# Universal app: compile each architecture, then merge them with lipo.
for ARCH in arm64 x86_64; do
  swiftc -parse-as-library -swift-version 5 -O \
    -target "$ARCH-apple-macos14" \
    Sources/*.swift -o "build/Converterator-$ARCH"
done
lipo -create build/Converterator-arm64 build/Converterator-x86_64 \
  -output "$APP/Contents/MacOS/Converterator"

PSX="$APP/Contents/Resources/psxpackager"
cp vendor/osx-arm64/psxpackager "$PSX/psxpackager-arm64"
cp vendor/osx-x64/psxpackager "$PSX/psxpackager-x86_64"
cp -R vendor/osx-arm64/Resources "$PSX/Resources"   # identical in both builds
cp vendor/LICENSE-psxpackager "$PSX/LICENSE"
cp LICENSE "$APP/Contents/Resources/LICENSE"
# chdman with MAME's licenses and a note on exactly which source it was built from
ditto "vendor/chdman-$CHDMAN_VERSION" "$APP/Contents/Resources/chdman"
ditto "$XD" "$APP/Contents/Resources/xdelta3"

# App icon: compile the Icon Composer icon (light + dark variants, made by make_icon.swift).
# actool writes Assets.car (used by macOS for appearance-aware icons) and AppIcon.icns (fallback).
xcrun actool AppIcon.icon --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist build/actool-info.plist \
  --output-format human-readable-text --notices --warnings --errors | grep -v "^/\* com.apple.actool" || true
[[ -f "$APP/Contents/Resources/Assets.car" ]] || { echo "actool failed to build the icon"; exit 1; }

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Converterator</string>
  <key>CFBundleDisplayName</key><string>Converterator</string>
  <key>CFBundleIdentifier</key><string>local.converterator</string>
  <key>CFBundleExecutable</key><string>Converterator</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.14.0</string>
  <key>CFBundleVersion</key><string>20</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Disc Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>pbp</string><string>cue</string><string>bin</string><string>gdi</string><string>iso</string><string>chd</string><string>zip</string><string>7z</string></array>
    </dict>
  </array>
  <key>NSAppTransportSecurity</key>
  <dict>
    <!-- redump.org only serves plain HTTP; allow it for that one site, for downloading DAT files. -->
    <key>NSExceptionDomains</key>
    <dict>
      <key>redump.org</key>
      <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
    </dict>
  </dict>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Convert with Converterator</string></dict>
      <key>NSMessage</key><string>convertFiles</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key>
      <array><string>public.folder</string><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # Developer ID signing for notarization: hardened runtime + secure timestamp on every executable.
  # PSXPackager is a .NET app, which needs JIT and unsigned executable memory under hardened runtime.
  for bin in "$PSX"/psxpackager-*; do
    codesign --force --timestamp --options runtime \
      --entitlements psxpackager.entitlements --sign "$SIGN_IDENTITY" "$bin"
  done
  for tool in chdman xdelta3; do
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/$tool/$tool"
  done
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP"
  echo "Signed with: $SIGN_IDENTITY"
else
  codesign --force --sign - "$APP"   # ad-hoc: fine for your own Mac, not for distribution
fi
rm -rf build
echo "Built $APP"
