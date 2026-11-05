#!/bin/zsh
# The whole release, from a Mac (never from CI: this repository is public and
# its runner is self-hosted, the signing secrets stay off it):
#   1 tests and the real keyboard  2 universal Developer ID build
#   3 notarize + staple the app  4 DMG, notarize + staple
#   5 Sparkle update archive  6 appcast (signed, deltas)
#   7 with --publish: upload to R2 and check the public URLs.
#
#   scripts/release.sh             # build everything into dist/, upload nothing
#   scripts/release.sh --publish   # same, then publish
#
# Environment:
#   PHASED_ROLLOUT_INTERVAL=86400  spread the update over 7 × that many seconds
#   SKIP_BUILD=1                   reuse dist/ from a previous run (publish only)
#   NO_DEVICE_TEST=1               no keyboard on this Mac: skip `selftest`
#   R2_PREFIX=everest/test         publish somewhere else (update test)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/r2.sh
PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1

APP=dist/Everest.app
UPDATES=dist/updates
PREFIX="${R2_PREFIX:-everest}"
FEED="$PUBLIC_BASE/$PREFIX"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  [[ -z "$(git status --porcelain)" ]] || { echo "Uncommitted changes: a release comes from a clean tree." >&2; exit 1; }
  swift test
  if [[ "${NO_DEVICE_TEST:-0}" != "1" ]]; then
    # An update reaches every keyboard: check the real one first (read-only).
    swift build -c release
    "$(swift build -c release --show-bin-path)/everest" selftest
  fi
  ./make-app.sh --release
  rm -rf dist
  mkdir -p dist
  mv Everest.app "$APP"
  scripts/notarize.sh "$APP"
  DMG=$(scripts/dmg.sh | tail -1)
  scripts/notarize.sh "$DMG"
fi

VERSION=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)
BUILD=$(defaults read "$PWD/$APP/Contents/Info" CFBundleVersion)
MIN_OS=$(defaults read "$PWD/$APP/Contents/Info" LSMinimumSystemVersion)
DMG="dist/Everest-$VERSION.dmg"
NOTES_JSON="ReleaseNotes/$VERSION.json"
[[ -f "$NOTES_JSON" ]] || { echo "Missing $NOTES_JSON" >&2; exit 1; }
xcrun stapler validate "$APP" >/dev/null
xcrun stapler validate "$DMG" >/dev/null

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  # 5. The update archive, next to the previous ones (for deltas) and the live appcast.
  rm -rf "$UPDATES"
  mkdir -p "$UPDATES"
  if public_exists "$PREFIX/appcast.xml"; then
    curl -fsS -o "$UPDATES/appcast.xml" "$FEED/appcast.xml"
    for url in $(grep -o 'url="[^"]*\.zip"' "$UPDATES/appcast.xml" | sed 's/^url="//; s/"$//' | head -3); do
      curl -fsS -o "$UPDATES/${url:t}" "$url"
    done
  fi
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$UPDATES/Everest-$VERSION.zip"

  # 6. Sign and write the appcast. The private key goes from Infisical to
  # generate_appcast through a pipe: no file, no keychain item.
  TOOLS=$(scripts/sparkle-tools.sh)
  args=(--download-url-prefix "$FEED/" --maximum-deltas 3 --link "https://mrrcalendar.com/everest" -o "$UPDATES/appcast.xml")
  [[ -n "${PHASED_ROLLOUT_INTERVAL:-}" ]] && args+=(--phased-rollout-interval "$PHASED_ROLLOUT_INTERVAL")
  sec /apple SPARKLE_ED_PRIVATE_KEY_EVEREST_MAC | "$TOOLS/generate_appcast" --ed-key-file - "${args[@]}" "$UPDATES"
  grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$UPDATES/appcast.xml"
  grep -q 'sparkle:edSignature=' "$UPDATES/appcast.xml"
  python3 scripts/release_notes.py link "$UPDATES/appcast.xml" "$VERSION" "$FEED/release-notes/$VERSION.html"
  python3 scripts/release_notes.py html "$NOTES_JSON" "dist/release-notes/$VERSION.html"
  python3 scripts/release_notes.py latest "$NOTES_JSON" --build "$BUILD" --dmg "$DMG" --url "$FEED/Everest-$VERSION.dmg" --min-os "$MIN_OS" > dist/latest.json
fi

echo "Ready: $DMG, $UPDATES/Everest-$VERSION.zip, $UPDATES/appcast.xml, dist/latest.json"
[[ "$PUBLISH" == "1" ]] || { echo "Not published (run with --publish)."; exit 0; }

# 7. Publish: immutable files first, the appcast and latest.json last.
r2_put "$DMG" "$PREFIX/Everest-$VERSION.dmg" application/x-apple-diskimage "$IMMUTABLE"
r2_put "$UPDATES/Everest-$VERSION.zip" "$PREFIX/Everest-$VERSION.zip" application/zip "$IMMUTABLE"
for delta in "$UPDATES"/*.delta(N); do
  public_exists "$PREFIX/${delta:t}" || r2_put "$delta" "$PREFIX/${delta:t}" application/octet-stream "$IMMUTABLE"
done
r2_put "dist/release-notes/$VERSION.html" "$PREFIX/release-notes/$VERSION.html" "text/html; charset=utf-8" "$SHORT"
r2_put "$UPDATES/appcast.xml" "$PREFIX/appcast.xml" "application/xml; charset=utf-8" "$SHORT"
r2_put dist/latest.json "$PREFIX/latest.json" application/json "$SHORT"

# Check what the world sees.
for key in "$PREFIX/Everest-$VERSION.dmg" "$PREFIX/Everest-$VERSION.zip" "$PREFIX/release-notes/$VERSION.html" "$PREFIX/appcast.xml" "$PREFIX/latest.json"; do
  public_exists "$key" || { echo "Not reachable: $PUBLIC_BASE/$key" >&2; exit 1; }
done
curl -fsS "$FEED/latest.json" | grep -q "\"version\": \"$VERSION\""
curl -fsS "$FEED/appcast.xml" | grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"
CHECK=$(mktemp -d)
curl -fsS -o "$CHECK/Everest.dmg" "$FEED/Everest-$VERSION.dmg"
xcrun stapler validate "$CHECK/Everest.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$CHECK/Everest.dmg"
rm -rf "$CHECK"
echo "Published Everest $VERSION ($BUILD)."
