#!/bin/sh
# Print the directory holding Sparkle's CLI tools (generate_keys, sign_update, generate_appcast).
# They ship inside the SwiftPM artifact after `swift package resolve`.
set -eu
cd "$(dirname "$0")/.."
[ -d .build/artifacts ] || swift package resolve >/dev/null
d=$(find .build/artifacts -type f -name sign_update -path '*/bin/*' | head -n 1)
[ -n "$d" ] || { echo "Sparkle tools not found; run: swift package resolve" >&2; exit 1; }
dirname "$d"
