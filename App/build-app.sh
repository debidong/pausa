#!/bin/sh
# Build Pausa.app (release, ad-hoc signed) into ./build/. Usage: App/build-app.sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product Pausa
BIN="$(swift build -c release --show-bin-path)/Pausa"
APP=build/Pausa.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp App/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Pausa"
# Resources: Finder icon (fixed: watercolor) + the in-app icon choices. Must be in place before codesign.
# Sources live in App/logo/; an upscaled NAME@1024.png wins over NAME.png when present.
RES="$APP/Contents/Resources"; mkdir -p "$RES"
logo() { if [ -f "App/logo/$1@1024.png" ]; then echo "App/logo/$1@1024.png"; else echo "App/logo/$1.png"; fi; }
ICONTMP=$(mktemp -d)
swift App/icon-tool.swift "$(logo icon-watercolor)" "$ICONTMP/ink.png" 1024
swift App/icon-tool.swift "$(logo icon-glass)" "$ICONTMP/glass.png" 1024
cp "$ICONTMP/ink.png" "$RES/icon-ink.png"       # full 1024 so the settings tiles stay crisp on Retina
cp "$ICONTMP/glass.png" "$RES/icon-glass.png"
SET="$ICONTMP/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONTMP/ink.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONTMP/ink.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$RES/AppIcon.icns"
cp "$RES/AppIcon.icns" App/AppIcon.icns     # keep the generated icon in the repo
rm -rf "$ICONTMP"
# Long-break backgrounds (optional): design/backgrounds/*.png -> Resources/backgrounds.
if ls design/backgrounds/*.png >/dev/null 2>&1; then
  mkdir -p "$RES/backgrounds"; cp design/backgrounds/*.png "$RES/backgrounds/"
  echo "backgrounds: $(ls design/backgrounds/*.png | wc -l | tr -d ' ') png"
else
  echo "backgrounds: none (using drawn scenery)"
fi
# SwiftPM stamps the binary with sdk = deployment target (13.0), which makes AppKit
# run it in old-look compatibility mode. Record the real SDK so macOS 26+ uses Liquid Glass.
vtool -set-build-version macos 13.0 "$(xcrun --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/Pausa.tmp" "$APP/Contents/MacOS/Pausa" 2>/dev/null
mv "$APP/Contents/MacOS/Pausa.tmp" "$APP/Contents/MacOS/Pausa"
codesign --force --sign - "$APP"
echo "$APP"
