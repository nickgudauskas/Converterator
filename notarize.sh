#!/bin/zsh
# Builds a Developer ID–signed Converterator.app, notarizes it with Apple, staples the ticket,
# and writes dist/Converterator.zip ready to upload to a GitHub release.
#
# One-time setup (stores your notarization login in the Keychain):
#   xcrun notarytool store-credentials converterator-notary \
#     --apple-id <your Apple ID email> --team-id <your Team ID>
# It asks for an app-specific password, made at https://account.apple.com → Sign-In and Security.
#
# Usage:  ./notarize.sh
# Env:    SIGN_IDENTITY  (default "Developer ID Application" — matches your certificate)
#         NOTARY_PROFILE (default "converterator-notary")
set -euo pipefail
cd "${0:A:h}"

export SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-converterator-notary}"
APP="Converterator.app"
ZIP="dist/Converterator.zip"

./build.sh

echo "Checking signature…"
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p dist
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "Submitting to Apple (usually takes a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json \
  | tee dist/notary-result.json
STATUS=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' dist/notary-result.json)
if [[ "$STATUS" != "Accepted" ]]; then
  ID=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' dist/notary-result.json)
  echo "Notarization $STATUS. Apple's log:"
  xcrun notarytool log "$ID" --keychain-profile "$PROFILE"
  exit 1
fi

echo "Stapling the notarization ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Re-zip so the download carries the stapled ticket (works even offline).
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
echo "Done: $ZIP is signed, notarized and stapled."
