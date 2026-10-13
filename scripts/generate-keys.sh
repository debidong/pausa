#!/bin/sh
# One-time: create the Sparkle EdDSA key pair (macOS only; private key goes to the login Keychain).
# Prints the public key for App/Info.plist SUPublicEDKey, and exports the private key to a file
# you paste into the GitHub secret SPARKLE_ED_PRIVATE_KEY, then back up and delete.
set -eu
BIN=$("$(dirname "$0")/sparkle-tools.sh")
"$BIN/generate_keys"                      # creates the key if missing, prints the public key
OUT="${1:-sparkle_ed_private_key.txt}"
"$BIN/generate_keys" -x "$OUT"
echo "Private key exported to $OUT. Add it as SPARKLE_ED_PRIVATE_KEY, back it up offline, then delete this file."
