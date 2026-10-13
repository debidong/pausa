#!/bin/sh
# README hero (2048x1280 = 1024x640 pt @2x; README shows it at width 100%), end to end, on a Mac (macOS 26+ for Liquid Glass). Usage: scripts/make-hero.sh
# Builds Pausa Dev (the --hero-mock entry exists only in DEV=1 builds), then:
#   1. captures each scene bare (no UI) from a 1024x640 pt mock window,
#   2. make-hero.py lays them out as five soft-edged strips (2048x1280 backdrop),
#   3. opens the mock once over that backdrop; that single window capture (2x) IS docs/images/hero.png.
# The mock is its own process with no scheduler: it never touches the running Pausa / Pausa Dev,
# its timers or break history, and writes no settings. Needs Pillow (pip3 install pillow).
set -eu
cd "$(dirname "$0")/.."
ARCHS=arm64 DEV=1 sh App/build-app.sh
BIN="build/Pausa Dev.app/Contents/MacOS/Pausa"
OUT=$(mktemp -d)
shot() {   # shot <out.png> <mock args...>
  f=$1; shift
  "$BIN" --hero-mock "$@" > "$OUT/wid" 2>> "$OUT/log" &
  pid=$!
  sleep 4.5   # first frame + glass settle; the window must be key, or glass draws flat
  screencapture -l "$(head -n 1 "$OUT/wid")" -o -x "$f"
  wait "$pid"
  tail -n 1 "$OUT/log"   # want key=true: an inactive window draws glass flat
}
for t in forest ocean sunset night; do shot "$OUT/bare-$t.png" "$t" 7 --bare; done
sips -s format png App/backgrounds/system-base.heic --out "$OUT/system-base.png" >/dev/null
python3 scripts/make-hero.py "$OUT" "$OUT/backdrop.png"
shot docs/images/hero.png "$OUT/backdrop.png" 7
echo docs/images/hero.png
