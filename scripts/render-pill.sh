#!/bin/zsh
# Real-window screenshots of the cursor pill (frosted glass cannot be drawn by ImageRenderer).
# Usage: scripts/render-pill.sh <out-dir> [path-to-debug-Pausa]
# Shows the pill next to the pointer for a few seconds, once per {light, dark} x {countdown 7, typing}.
# It appears on the real screen, so run it when nobody is working on this Mac.
set -e
out=${1:?out dir}; bin=${2:-.build/debug/Pausa}
mkdir -p "$out"
for ap in light dark; do
  PAUSA_CAPTURABLE=1 PAUSA_APPEARANCE=$ap "$bin" --debug-show-prebreak --screen pointer --kind short --from 7 --hold 9 >/dev/null 2>&1 &
  pid=$!
  sleep 2.2   # the pill needs the countdown to reach 7 or less; it follows the pointer at 30 Hz
  rect=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var m=$.NSEvent.mouseLocation, h=$.NSScreen.screens.objectAtIndex(0).frame.size.height; Math.round(m.x+4)+","+Math.round(h-m.y+4)+",190,56"')
  screencapture -x -R "$rect" "$out/pill-$ap.png"
  wait $pid || true
done
echo "wrote $out/pill-{light,dark}.png"
