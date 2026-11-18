#!/bin/zsh
# Builds "Converterator.app" next to this script.
set -euo pipefail
cd "${0:A:h}"

APP="Converterator.app"
PSX_VERSION="v1.8.0"
case "$(uname -m)" in
  arm64) ARCH=arm64; PSX_PLATFORM=osx-arm64 ;;
  *)     ARCH=x86_64; PSX_PLATFORM=osx-x64 ;;
esac

# PSXPackager isn't stored in this repo; fetch the release build once into vendor/.
if [[ ! -x vendor/psxpackager/psxpackager ]]; then
  echo "Downloading PSXPackager $PSX_VERSION ($PSX_PLATFORM)…"
  mkdir -p vendor
  curl -fsSL -o vendor/psxpackager.tar.gz \
    "https://github.com/RupertAvery/PSXPackager/releases/download/$PSX_VERSION/psxpackager-$PSX_PLATFORM.tar.gz"
  tar -xzf vendor/psxpackager.tar.gz -C vendor
  rm -rf vendor/psxpackager
  mv "vendor/psxpackager-$PSX_PLATFORM" vendor/psxpackager
  rm -f vendor/psxpackager.tar.gz vendor/psxpackager/README.md
fi

rm -rf "$APP" build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library -swift-version 5 -O \
  -target "$ARCH-apple-macos14" \
  main.swift -o "$APP/Contents/MacOS/Converterator"

cp -R vendor/psxpackager "$APP/Contents/Resources/psxpackager"

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
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
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

codesign --force --sign - "$APP"
rm -rf build
echo "Built $APP"
