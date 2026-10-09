#!/bin/sh
# Builds Everest.app — a double-clickable GUI app — next to this script.
# Usage: ./make-app.sh [--install | --zip]
#   --install copies it to /Applications; --zip also writes Everest-<version>.zip
set -e
cd "$(dirname "$0")"

swift build -c release

APP="Everest.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The bundle executable is the binary itself: with no arguments it opens the
# window (see main.swift), and the daemon it spawns is the very same code, so
# macOS sees one identity for the permissions.
cp .build/release/everest "$APP/Contents/MacOS/everest"

# App icon: assets/AppIcon.icns (made by tools/make-icon.swift from a logo file).
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# One version, in Sources/everest/Version.swift; the build is the commit
# count, with "+" when the working tree has uncommitted changes.
VERSION=$(sed -n 's/.*static let number = "\(.*\)".*/\1/p' Sources/everest/Version.swift)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
[ -n "$(git status --porcelain 2>/dev/null)" ] && BUILD="$BUILD+"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Everest</string>
    <key>CFBundleDisplayName</key><string>Everest</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string><string>de</string><string>es</string><string>it</string><string>pt</string><string>nb</string><string>sv</string><string>da</string><string>fi</string><string>ko</string><string>he</string></array>
    <key>CFBundleIdentifier</key><string>local.everest-mac</string>
    <key>CFBundleExecutable</key><string>everest</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
EOF

# macOS 15 kills copied binaries with a provenance xattr or a stale signature.
xattr -cr "$APP" 2>/dev/null || true

# Sign the whole bundle with a *stable* designated requirement. A plain ad-hoc
# signature is pinned to the binary's hash (cdhash H"..."), which changes on
# every build: macOS then keeps showing an old, ticked "Everest" entry in
# Privacy & Security > Accessibility that no longer matches the new build.
# Matching on the bundle identifier instead keeps the permission across builds.
codesign --force --sign - --identifier local.everest-mac \
    -r='designated => identifier "local.everest-mac"' "$APP"

# The bundle must be somewhere Gatekeeper allows executables to run from.
# A running copy keeps the old code in memory: quit it first, and open the
# new one if it was running.
if [ "$1" = "--install" ]; then
    WAS_RUNNING=0
    if pgrep -f "/Applications/$APP/Contents/MacOS/everest" >/dev/null; then
        WAS_RUNNING=1
        osascript -e 'quit app id "local.everest-mac"' >/dev/null 2>&1 || true
        sleep 2
        pkill -f "/Applications/$APP/Contents/MacOS/everest" 2>/dev/null || true
        sleep 1
    fi
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    echo "Installed /Applications/$APP ($VERSION, build $BUILD)"
    [ $WAS_RUNNING = 1 ] && open "/Applications/$APP"
fi

# A zip for a release page. The app is only ad-hoc signed, so downloaders must
# approve it once (right-click > Open, or xattr -dr com.apple.quarantine).
if [ "$1" = "--zip" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
    rm -f "Everest-$VERSION.zip"
    ditto -c -k --keepParent "$APP" "Everest-$VERSION.zip"
    echo "Wrote $(pwd)/Everest-$VERSION.zip"
fi

echo "Built $(pwd)/$APP — double-click it, or run: open $APP"
