#!/bin/zsh
# Once in the life of the project: creates the EdDSA key that signs Everest's
# updates. The private half goes straight to Infisical (agents, /apple,
# SPARKLE_ED_PRIVATE_KEY_EVEREST_MAC) and is never displayed; the public half is
# printed, for SPARKLE_PUBLIC_KEY in make-app.sh.
#
# Never run it again once a release is out: installed apps would refuse every
# update signed with another key. It refuses to replace an existing key.
#
#   scripts/create-update-key.sh --dry-run   # checks the key format, stores nothing
#   scripts/create-update-key.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/r2.sh
NAME=SPARKLE_ED_PRIVATE_KEY_EVEREST_MAC
TOOLS=$(scripts/sparkle-tools.sh)
DIR=$(mktemp -d)
chmod 700 "$DIR"
trap 'rm -rf "$DIR"' EXIT

openssl genpkey -algorithm ed25519 -out "$DIR/private.pem" 2>/dev/null
openssl pkey -in "$DIR/private.pem" -pubout -out "$DIR/public.pem"
# Sparkle's key file is the base64 of the 32-byte seed: the end of the DER form.
( umask 077; openssl pkey -in "$DIR/private.pem" -outform DER | tail -c 32 | base64 > "$DIR/seed" )
PUBLIC=$(openssl pkey -in "$DIR/public.pem" -pubin -outform DER | tail -c 32 | base64)

# Sparkle must sign with it, and the signature must match the public half.
head -c 4096 /dev/urandom > "$DIR/sample"
"$TOOLS/sign_update" --ed-key-file "$DIR/seed" -p "$DIR/sample" | base64 -d > "$DIR/signature"
openssl pkeyutl -verify -pubin -inkey "$DIR/public.pem" -rawin -in "$DIR/sample" -sigfile "$DIR/signature" >/dev/null
echo "Key format checked with Sparkle's sign_update."

if [[ "${1:-}" == "--dry-run" ]]; then
  echo "Dry run: nothing stored."
  exit 0
fi

[[ -z "$(sec /apple "$NAME" 2>/dev/null || true)" ]] || { echo "$NAME already exists: not replacing it." >&2; exit 1; }
infisical secrets set "$NAME=@$DIR/seed" --path /apple \
  --projectId 67596dbd-6bef-4d36-96db-426716df1c81 --env prod \
  --domain https://infisical.amorem.cloud/api >/dev/null
[[ "$(sec /apple "$NAME")" == "$(cat "$DIR/seed")" ]] || { echo "The stored key does not match." >&2; exit 1; }
echo "Stored in Infisical: /apple/$NAME"
echo "Public key: $PUBLIC"
