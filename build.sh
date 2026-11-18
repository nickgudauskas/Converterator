#!/bin/zsh
# Builds "Converterator.app" next to this script.
# Ad-hoc signed by default. Set SIGN_IDENTITY (e.g. "Developer ID Application") to sign for
# distribution; notarize.sh does that for you.
set -euo pipefail
cd "${0:A:h}"

APP="Converterator.app"
PSX_VERSION="v1.8.0"

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

rm -rf "$APP" build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources/psxpackager"

# Universal app: compile each architecture, then merge them with lipo.
for ARCH in arm64 x86_64; do
  swiftc -parse-as-library -swift-version 5 -O \
    -target "$ARCH-apple-macos14" \
    main.swift -o "build/Converterator-$ARCH"
done
lipo -create build/Converterator-arm64 build/Converterator-x86_64 \
  -output "$APP/Contents/MacOS/Converterator"

PSX="$APP/Contents/Resources/psxpackager"
cp vendor/osx-arm64/psxpackager "$PSX/psxpackager-arm64"
cp vendor/osx-x64/psxpackager "$PSX/psxpackager-x86_64"
cp -R vendor/osx-arm64/Resources "$PSX/Resources"   # identical in both builds
cp vendor/LICENSE-psxpackager "$PSX/LICENSE"
cp LICENSE "$APP/Contents/Resources/LICENSE"

# Optional custom icon: drop an icon.icns next to this script.
if [[ -f icon.icns ]]; then cp icon.icns "$APP/Contents/Resources/AppIcon.icns"; fi

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
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Disc Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>pbp</string><string>cue</string><string>bin</string><string>gdi</string><string>iso</string></array>
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
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP"
  echo "Signed with: $SIGN_IDENTITY"
else
  codesign --force --sign - "$APP"   # ad-hoc: fine for your own Mac, not for distribution
fi
rm -rf build
echo "Built $APP"
