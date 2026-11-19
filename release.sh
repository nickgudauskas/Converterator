#!/bin/zsh
# Publishes a Converterator release, stopping at the first problem:
#   1. checks: on main, nothing uncommitted, version newer than the latest release, gh signed in
#   2. runs the tests (no release if any fail)
#   3. sets the version in build.sh
#   4. builds, signs, notarizes and staples (notarize.sh)
#   5. commits the version change, pushes, and publishes the GitHub release with the zip
#   6. downloads the release back and checks its checksum, signature, notarization and version
#
# Usage:  ./release.sh 1.12.0 [notes.md] [--dry-run]
#   notes.md   release notes (Markdown). Without it, the commit messages since the last release are used.
#   --dry-run  do the checks and run the tests, then stop without changing or publishing anything.
#
# It doesn't install the new version on this Mac: use Check for Updates → Install and Relaunch.
set -euo pipefail
cd "${0:A:h}"

REPO="nickgudauskas/Converterator"
VERSION="" NOTES="" DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    *.md|*.txt) NOTES="$a" ;;
    *) VERSION="$a" ;;
  esac
done
step() { print -P "\n%B▶ $1%b"; }
fail() { print -P "%F{red}✗ $1%f"; exit 1; }

# 1. Checks
step "Checking"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || fail "Give a version number, e.g. ./release.sh 1.12.0"
[[ -z "$NOTES" || -f "$NOTES" ]] || fail "Notes file not found: $NOTES"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "Switch to the main branch first."
[[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first:\n$(git status --short)"
gh auth status >/dev/null 2>&1 || fail "Sign in to GitHub first: gh auth login"
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" || -n "$(git log origin/main..HEAD --oneline)" ]] \
  || fail "main is behind GitHub; pull first."
LATEST=$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>/dev/null || echo "v0")
newer() {  # is $1 newer than $2? (numeric, so 1.10 > 1.9)
  /usr/bin/python3 -I -c 'import sys
p = lambda s: [int(x) for x in s.lstrip("vV").split(".")]
a, b = p(sys.argv[1]), p(sys.argv[2]); n = max(len(a), len(b))
sys.exit(0 if a + [0]*(n-len(a)) > b + [0]*(n-len(b)) else 1)' "$1" "$2"
}
newer "$VERSION" "$LATEST" || fail "$VERSION isn't newer than the latest release ($LATEST)."
print "Releasing $VERSION (latest is $LATEST)."

# 2. Tests
step "Running the tests"
./tests/test.sh || fail "Tests failed, so nothing was released."

# Release notes: the file given, or the commit messages since the last release.
NOTES_TEXT=""
if [[ -n "$NOTES" ]]; then
  NOTES_TEXT=$(cat "$NOTES")
else
  RANGE="HEAD"; git rev-parse -q --verify "refs/tags/$LATEST" >/dev/null && RANGE="$LATEST..HEAD"
  NOTES_TEXT=$(git log "$RANGE" --no-merges --pretty='- %s')
fi

if (( DRY )); then
  step "Dry run: stopping here"
  print "Would set build.sh to $VERSION, notarize, commit, push and publish v$VERSION with these notes:\n"
  print -r -- "$NOTES_TEXT"
  exit 0
fi

# 3. Version
step "Setting the version"
CURRENT=$(sed -nE 's#.*<key>CFBundleShortVersionString</key><string>([^<]+)</string>.*#\1#p' build.sh)
BUILD=$(sed -nE 's#.*<key>CFBundleVersion</key><string>([0-9]+)</string>.*#\1#p' build.sh)
if [[ "$CURRENT" != "$VERSION" ]]; then
  BUILD=$((BUILD + 1))
  sed -i '' -E "s#(<key>CFBundleShortVersionString</key><string>)[^<]+(</string>)#\1$VERSION\2#; s#(<key>CFBundleVersion</key><string>)[0-9]+(</string>)#\1$BUILD\2#" build.sh
fi
print "Version $VERSION, build $BUILD."

# 4. Build and notarize
step "Building and notarizing (a few minutes)"
./notarize.sh
ZIP="dist/Converterator.zip"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Converterator.app/Contents/Info.plist)
[[ "$BUILT" == "$VERSION" ]] || fail "The built app says $BUILT, not $VERSION."

# 5. Commit, push, publish
step "Publishing"
if [[ -n "$(git status --porcelain build.sh)" ]]; then
  git add build.sh
  git commit -q -m "Release $VERSION" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
fi
git push -q origin main
{
  print -r -- "$NOTES_TEXT"
  print "\nUniversal (Apple Silicon and Intel), signed and notarized. From 1.7.0, **Check for Updates → Install and Relaunch** installs this release for you."
  print "\nSHA-256 of \`Converterator.zip\`: \`$SHA\`"
} | gh release create "v$VERSION" "$ZIP" --target main --title "Converterator $VERSION" --notes-file -

# 6. Check what was published
step "Checking the published release"
T=$(mktemp -d "${TMPDIR:-/tmp}/converterator-release.XXXXXX")
trap 'rm -rf "$T"' EXIT
gh release download "v$VERSION" -R "$REPO" -D "$T"
[[ "$(shasum -a 256 "$T/Converterator.zip" | cut -d' ' -f1)" == "$SHA" ]] || fail "The downloaded zip's checksum doesn't match."
ditto -x -k "$T/Converterator.zip" "$T/x"
spctl --assess --type execute "$T/x/Converterator.app" || fail "Gatekeeper rejects the downloaded app."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$T/x/Converterator.app/Contents/Info.plist")" == "$VERSION" ]] \
  || fail "The downloaded app has the wrong version."
[[ "$(gh api "repos/$REPO/releases/latest" --jq .tag_name)" == "v$VERSION" ]] || fail "GitHub doesn't list v$VERSION as the latest release."

print -P "\n%F{green}✓ Released $VERSION%f: https://github.com/$REPO/releases/tag/v$VERSION"
print "SHA-256 $SHA. Update this Mac with Check for Updates → Install and Relaunch."
