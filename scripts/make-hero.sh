#!/bin/sh
# README hero, end to end, on a Mac (macOS 26+ for Liquid Glass). Usage: scripts/make-hero.sh
# Builds Pausa Dev (the --hero-mock entry exists only in DEV=1 builds), opens one ordinary
# 1024x640 mock window per scene for a few seconds, captures just that window, then composites.
# The mock runs as its own process with no scheduler: it never touches the running Pausa / Pausa Dev,
# its timers or break history, and writes no settings. Needs Pillow (pip3 install pillow).
set -eu
cd "$(dirname "$0")/.."
ARCHS=arm64 DEV=1 sh App/build-app.sh
BIN="build/Pausa Dev.app/Contents/MacOS/Pausa"
OUT=$(mktemp -d)
for t in forest ocean sunset night; do
  "$BIN" --hero-mock "$t" 7 > "$OUT/wid" &
  pid=$!
  sleep 4.5   # first frame + glass settle; the window must be key, or glass draws flat
  screencapture -l "$(head -n 1 "$OUT/wid")" -o -x "$OUT/mock-$t.png"
  wait "$pid"
done
sips -s format png App/backgrounds/system-base.heic --out "$OUT/system-base.png" >/dev/null
python3 scripts/make-hero.py "$OUT" docs/images/hero.png
