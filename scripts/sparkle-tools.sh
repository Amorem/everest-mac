#!/bin/zsh
# Prints the directory holding Sparkle's command line tools (generate_appcast,
# sign_update, generate_keys), downloading the pinned release once into
# build/sparkle-tools/<version> after checking its SHA-256.
# Keep SPARKLE_VERSION in step with the Sparkle package in Package.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
SPARKLE_VERSION=2.9.4
SPARKLE_SHA256=ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9
DIR="build/sparkle-tools/$SPARKLE_VERSION"
if [[ ! -x "$DIR/bin/generate_appcast" ]]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/Sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "$SPARKLE_SHA256  $TMP/Sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
  mkdir -p "$DIR"
  tar -xJf "$TMP/Sparkle.tar.xz" -C "$DIR" ./bin
fi
echo "$PWD/$DIR/bin"
