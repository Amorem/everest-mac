#!/bin/sh
# Install everest's button daemon as a per-user LaunchAgent.
#
# The agent runs `everest listen`, which watches the numpad buttons (D1-D4)
# and executes the actions from ~/.config/everest-mac/config.json.
#
# Usage: ./install-daemon.sh [--uninstall]
set -e

BIN="$(pwd)/.build/release/everest"
for candidate in "$HOME/bin/everest" "$HOME/.local/bin/everest"; do
    if [ -x "$candidate" ]; then
        BIN="$candidate"
        break
    fi
done
LABEL="com.everest.listen"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "$1" = "--uninstall" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed $LABEL"
    exit 0
fi

if [ ! -x "$BIN" ]; then
    echo "Build first: swift build -c release" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.config/everest-mac"
if [ ! -f "$HOME/.config/everest-mac/config.json" ]; then
    "$BIN" init-config
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>listen</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>$HOME/.config/everest-mac/listen.log</string>
    <key>StandardOutPath</key>
    <string>$HOME/.config/everest-mac/listen.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL — logs: ~/.config/everest-mac/listen.log"
echo "Config:  ~/.config/everest-mac/config.json"
