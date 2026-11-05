#!/bin/zsh
# Packs dist/Everest.app into dist/Everest-<version>.dmg (drag to Applications)
# and signs the image with the Developer ID identity.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=dist/Everest.app
VERSION=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)
DMG="dist/Everest-$VERSION.dmg"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Everest.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Everest for Mac" -srcfolder "$STAGE" -fs APFS -format ULFO "$DMG" -quiet
rm -rf "$STAGE"
codesign --sign "Developer ID Application: AMOREM (962QD3N57U)" --timestamp "$DMG"
echo "$DMG"
