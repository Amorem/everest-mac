#!/bin/sh
# Build, install ~/bin/everest and the Everest.app bundle.
#
# macOS 15 kills freshly copied binaries that carry a provenance xattr or an
# invalid signature, so every copy is cleaned and re-signed ad-hoc.
set -e
cd "$(dirname "$0")"

swift build -c release

mkdir -p "$HOME/bin"
cp .build/release/everest "$HOME/bin/everest"
xattr -c "$HOME/bin/everest" 2>/dev/null || true
codesign --force --sign - "$HOME/bin/everest" >/dev/null 2>&1 || true

./make-app.sh >/dev/null

echo "Installed:"
echo "  $HOME/bin/everest        (CLI + 'everest gui')"
echo "  $(pwd)/Everest.app        (double-click)"
echo
echo "Make sure ~/bin is on your PATH (see ~/.zshrc)."
