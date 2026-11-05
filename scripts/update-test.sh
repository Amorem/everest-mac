#!/bin/zsh
# A real Sparkle update, end to end, before publishing: an old build (0.1.9)
# downloads, verifies and installs this code from a TEST feed on R2, then
# relaunches. Signed with a throwaway key made here: the real key is not used,
# and nothing touches the real feed. The test app sends nothing to the devices.
#
#   scripts/update-test.sh
#   scripts/update-test.sh --clean   # deletes everest/test/* from R2
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/r2.sh
PREFIX=everest/test
VERSION=$(sed -n 's/.*static let number = "\(.*\)".*/\1/p' Sources/everest/Version.swift)
TEST=build/update-test

if [[ "${1:-}" == "--clean" ]]; then
  for key in "$PREFIX/Everest-$VERSION.zip" "$PREFIX/appcast.xml"; do
    r2_delete "$key"
  done
  rm -rf "$TEST"
  defaults delete com.mrrcalendar.everest 2>/dev/null || true
  exit 0
fi

rm -rf "$TEST"
mkdir -p "$TEST/feed" "$TEST/old" "$TEST/key"
chmod 700 "$TEST/key"
openssl genpkey -algorithm ed25519 -out "$TEST/key/private.pem" 2>/dev/null
( umask 077; openssl pkey -in "$TEST/key/private.pem" -outform DER | tail -c 32 | base64 > "$TEST/key/seed" )
PUBLIC=$(openssl pkey -in "$TEST/key/private.pem" -pubout -outform DER | tail -c 32 | base64)
export EVEREST_FEED_URL="$PUBLIC_BASE/$PREFIX/appcast.xml"
export EVEREST_SPARKLE_PUBLIC_KEY="$PUBLIC"

# The new version, notarized like a release.
EVEREST_BUILD=2 ./make-app.sh --release >/dev/null
scripts/notarize.sh Everest.app
ditto -c -k --sequesterRsrc --keepParent Everest.app "$TEST/feed/Everest-$VERSION.zip"
TOOLS=$(scripts/sparkle-tools.sh)
"$TOOLS/generate_appcast" --ed-key-file "$TEST/key/seed" --download-url-prefix "$PUBLIC_BASE/$PREFIX/" \
  -o "$TEST/feed/appcast.xml" "$TEST/feed"
r2_put "$TEST/feed/Everest-$VERSION.zip" "$PREFIX/Everest-$VERSION.zip" application/zip "no-cache"
r2_put "$TEST/feed/appcast.xml" "$PREFIX/appcast.xml" "application/xml; charset=utf-8" "no-cache"

# The old version, reading that feed.
EVEREST_VERSION=0.1.9 EVEREST_BUILD=1 ./make-app.sh --release >/dev/null
ditto Everest.app "$TEST/old/Everest.app"
rm -rf Everest.app
INSTALLED="$PWD/$TEST/old/Everest.app"
BIN="$INSTALLED/Contents/MacOS/everest"
defaults delete com.mrrcalendar.everest 2>/dev/null || true

EVEREST_UPDATE_TEST=1 EVEREST_CONFIG_DIR="$PWD/$TEST/config" "$BIN" >"$TEST/app.log" 2>&1 &
echo "Old build running, waiting for the update…"
for _ in {1..150}; do
  sleep 2
  now=$(defaults read "$INSTALLED/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")
  [[ "$now" == "$VERSION" ]] && break
done
[[ "$now" == "$VERSION" ]] || { pkill -f "$BIN" || true; cat "$TEST/app.log"; echo "FAILED: still on $now" >&2; exit 1; }
echo "Installed on disk: $now"

# The relaunched app runs for real (Sparkle does not pass the environment on):
# stop it at once, the Mac's own Everest is the one in charge.
for _ in {1..30}; do
  pgrep -f "$BIN" >/dev/null && break
  sleep 0.5
done
if pgrep -f "$BIN" >/dev/null; then echo "Relaunched: yes"; else echo "Relaunched: NO"; fi
pkill -f "$BIN" || true
codesign --verify --deep --strict "$INSTALLED" && echo "Signature after the update: valid"
codesign -dv "$INSTALLED" 2>&1 | grep -E 'TeamIdentifier|flags'
echo "OK"
