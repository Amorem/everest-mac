#!/bin/sh
# Builds Everest.app next to this script.
# Usage: ./make-app.sh [--install | --zip | --release]
#   --install   copies it to /Applications
#   --zip       also writes Everest-<version>.zip (ad-hoc signed, for testing)
#   --release   universal, Developer ID signed, hardened, with the update feed:
#               what scripts/release.sh notarises and publishes
set -e
cd "$(dirname "$0")"

BUNDLE_ID=$(sed -n 's/.*static let bundleIdentifier = "\(.*\)".*/\1/p' Sources/everest/Version.swift)
LEGACY_BUNDLE_ID=$(sed -n 's/.*static let legacyBundleIdentifier = "\(.*\)".*/\1/p' Sources/everest/Version.swift)
SIGN_IDENTITY="Developer ID Application: AMOREM (962QD3N57U)"
# The update feed and the public half of the signing key: both are read by the
# installed apps for ever. Never change the key (Infisical agents, /apple,
# SPARKLE_ED_PRIVATE_KEY_EVEREST_MAC holds the private half).
FEED_URL="${EVEREST_FEED_URL:-https://downloads.mrrcalendar.com/everest/appcast.xml}"
SPARKLE_PUBLIC_KEY="${EVEREST_SPARKLE_PUBLIC_KEY:-F8KA22bV9r4p3U1/8J3OW25UGT21PNFDJLENE6e6RJI=}"

if [ "$1" = "--release" ]; then
    ARCHS="--arch arm64 --arch x86_64"
else
    ARCHS=""
fi
# shellcheck disable=SC2086
swift build -c release $ARCHS
# shellcheck disable=SC2086
BIN_DIR=$(swift build -c release $ARCHS --show-bin-path)

APP="Everest.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
# The bundle executable is the binary itself: with no arguments it opens the
# window (see main.swift), and the daemon it spawns is the very same code, so
# macOS sees one identity for the permissions.
cp "$BIN_DIR/everest" "$APP/Contents/MacOS/everest"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# The XPC services are for sandboxed apps; Everest cannot be sandboxed.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

# App icon: assets/AppIcon.icns (made with `everest app-icon`, see BrandMark.swift).
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# One version, in Sources/everest/Version.swift; the build is the commit
# count, with "+" when the working tree has uncommitted changes.
VERSION=$(sed -n 's/.*static let number = "\(.*\)".*/\1/p' Sources/everest/Version.swift)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
[ -n "$(git status --porcelain 2>/dev/null)" ] && BUILD="$BUILD+"
# scripts/update-test.sh builds an "older" app and a newer one.
VERSION="${EVEREST_VERSION:-$VERSION}"
BUILD="${EVEREST_BUILD:-$BUILD}"

# Only a release build updates itself: a build from source stays as it is.
UPDATE_KEYS=""
if [ "$1" = "--release" ]; then
    UPDATE_KEYS="    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUAllowsAutomaticUpdates</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Everest</string>
    <key>CFBundleDisplayName</key><string>Everest</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string><string>de</string><string>es</string><string>it</string><string>pt</string><string>nb</string><string>sv</string><string>da</string><string>fi</string><string>ko</string><string>he</string></array>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>everest</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- The GUI opts into the Dock when requested. Helper processes using
         this executable must remain agents too, without a launch Dock tile. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
$UPDATE_KEYS
</dict>
</plist>
EOF

# macOS 15 kills copied binaries with a provenance xattr or a stale signature.
xattr -cr "$APP" 2>/dev/null || true

FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [ "$1" = "--release" ]; then
    # Developer ID, hardened runtime, secure timestamp, from the inside out.
    # Its designated requirement (team + identifier) keeps the permissions
    # across updates. No entitlement is needed: nothing is sandboxed, and HID
    # and USB access are not restricted by the hardened runtime.
    sign() { codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$@"; }
    sign "$FRAMEWORK/Versions/B/Autoupdate"
    sign "$FRAMEWORK/Versions/B/Updater.app"
    sign "$FRAMEWORK"
    sign --identifier "$BUNDLE_ID" "$APP"
    codesign --verify --deep --strict "$APP"
else
    # Sign the whole bundle with a *stable* designated requirement. A plain
    # ad-hoc signature is pinned to the binary's hash (cdhash H"..."), which
    # changes on every build: macOS then keeps showing an old, ticked "Everest"
    # entry in Privacy & Security > Accessibility that no longer matches the new
    # build. Matching on the bundle identifier instead keeps the permission
    # across builds.
    codesign --force --deep --sign - "$FRAMEWORK"
    codesign --force --sign - --identifier "$BUNDLE_ID" \
        -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
fi

# The bundle must be somewhere Gatekeeper allows executables to run from.
# A running copy keeps the old code in memory: quit it first, and open the
# new one if it was running.
if [ "$1" = "--install" ]; then
    WAS_RUNNING=0
    if pgrep -f "/Applications/$APP/Contents/MacOS/everest" >/dev/null; then
        WAS_RUNNING=1
        osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
        osascript -e "quit app id \"$LEGACY_BUNDLE_ID\"" >/dev/null 2>&1 || true
        sleep 2
        pkill -f "/Applications/$APP/Contents/MacOS/everest" 2>/dev/null || true
        sleep 1
    fi
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    echo "Installed /Applications/$APP ($VERSION, build $BUILD)"
    [ $WAS_RUNNING = 1 ] && open "/Applications/$APP"
fi

# A zip of a local build, for testing (CI keeps it as an artifact). It is only
# ad-hoc signed: what people download comes from scripts/release.sh.
if [ "$1" = "--zip" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
    rm -f "Everest-$VERSION.zip"
    ditto -c -k --keepParent "$APP" "Everest-$VERSION.zip"
    echo "Wrote $(pwd)/Everest-$VERSION.zip"
fi

echo "Built $(pwd)/$APP — double-click it, or run: open $APP"
