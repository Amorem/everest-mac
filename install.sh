#!/bin/sh
# Builds and installs Everest.app, and puts the `everest` command in ~/bin.
#
# The command is a link into the app, not a copy: the binary loads Sparkle from
# the bundle, and a link also follows the app's updates.
set -e
cd "$(dirname "$0")"

./make-app.sh --install >/dev/null

mkdir -p "$HOME/bin"
ln -sf /Applications/Everest.app/Contents/MacOS/everest "$HOME/bin/everest"

echo "Installed:"
echo "  /Applications/Everest.app  (double-click)"
echo "  $HOME/bin/everest          (CLI + 'everest gui')"
echo
echo "Make sure ~/bin is on your PATH (see ~/.zshrc)."
