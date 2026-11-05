#!/bin/zsh
# Notarizes and staples an app or a DMG, then checks Gatekeeper.
#   scripts/notarize.sh dist/Everest.app        # zipped for the upload, the app is stapled
#   scripts/notarize.sh dist/Everest-0.2.0.dmg
# Uses the notarytool profile `macos-release-notary` in its own keychain (see
# ~/Git/vps-infra/docs/agents-secrets.md, "Signer et notariser depuis un autre
# Mac": the values come from Infisical and are never written here).
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-macos-release-notary}"
KEYCHAIN="${NOTARY_KEYCHAIN-$HOME/Library/Keychains/macos-release-notary.keychain-db}"
TARGET="$1"
args=(--keychain-profile "$PROFILE")
if [[ -n "$KEYCHAIN" ]]; then
  security unlock-keychain -p "" "$KEYCHAIN" 2>/dev/null || true
  args+=(--keychain "$KEYCHAIN")
fi
if [[ "$TARGET" == *.app ]]; then
  ZIP=$(mktemp -d)/notarize.zip
  ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$ZIP"
  xcrun notarytool submit "$ZIP" "${args[@]}" --wait
  rm -f "$ZIP"
  xcrun stapler staple "$TARGET"
  spctl --assess --type execute --verbose=2 "$TARGET"
else
  xcrun notarytool submit "$TARGET" "${args[@]}" --wait
  xcrun stapler staple "$TARGET"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET"
fi
echo "Notarized $TARGET"
