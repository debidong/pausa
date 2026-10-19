#!/bin/sh
# Build Pausa.app into ./build/. Usage: App/build-app.sh
# Ad-hoc signed (no Developer ID). Env (optional):
#                 VERSION   CFBundleShortVersionString (e.g. 1.2.0, from the git tag)
#                 BUILD     CFBundleVersion, must strictly increase for Sparkle (CI: commit count)
#                 DEV=1     build "Pausa Dev.app": bundle ID app.getpausa.Pausa.dev, own settings and
#                           timer state, no Sparkle feed (never auto-updates). Can sit next to Pausa.
set -eu
cd "$(dirname "$0")/.."
# Universal binary (arm64 + x86_64). Build each arch into its own scratch dir so the slices
# never share a bin path (SwiftPM 6.x uses one .build/out for every triple), then lipo.
ARCHS="${ARCHS:-arm64 x86_64}"
SLICES=""
# DEV=1 also compiles the DEV-only tools (Sources/Pausa/Debug/HeroMock.swift).
FLAGS=""; if [ "${DEV:-}" = 1 ]; then FLAGS="-Xswiftc -DPAUSA_DEV"; fi
for a in $ARCHS; do
  swift build -c release $FLAGS --product Pausa --triple "$a-apple-macosx13.0" --scratch-path ".build/arch-$a"
  SLICES="$SLICES $(swift build -c release $FLAGS --triple "$a-apple-macosx13.0" --scratch-path ".build/arch-$a" --show-bin-path)/Pausa"
done
BIN_DIR="$(dirname $(echo $SLICES | cut -d' ' -f1))"
set -- $SLICES
if [ $# -gt 1 ]; then
  BIN="$BIN_DIR/Pausa.universal"
  lipo -create "$@" -output "$BIN"
else
  BIN="$1"   # one arch: no lipo (a one-slice fat file makes vtool segfault)
fi
echo "archs: $(lipo -archs "$BIN")"
if [ "${DEV:-}" = 1 ]; then APP="build/Pausa Dev.app"; else APP=build/Pausa.app; fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp App/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Pausa"
if [ -n "${VERSION:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"; fi
if [ -n "${BUILD:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"; fi
if [ "${DEV:-}" = 1 ]; then
  PL="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.getpausa.Pausa.dev" "$PL"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleName" "$PL" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string Pausa Dev" "$PL"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$PL" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Pausa Dev" "$PL"
  # No feed, no checks: a dev build is only ever replaced by hand.
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$PL" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" "$PL" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$PL"
  # pausa-dev://break?kind=short|long lets us trigger a break for testing. Dev builds only.
  /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$PL"
  /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$PL"
  /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string app.getpausa.Pausa.dev" "$PL"
  /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$PL"
  /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string pausa-dev" "$PL"
fi
# Sparkle.framework: SwiftPM drops the binary framework next to the executable; embed it in
# Contents/Frameworks and make the binary look there.
FW_SRC="$BIN_DIR/Sparkle.framework"
if [ ! -d "$FW_SRC" ]; then
  FW_SRC=$(find .build -path '*artifacts*macos*/Sparkle.framework' -maxdepth 8 -type d | head -n 1)
fi
[ -d "$FW_SRC" ] || { echo "Sparkle.framework not found" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$FW_SRC" "$APP/Contents/Frameworks/Sparkle.framework"   # ditto keeps the framework's symlinks
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Pausa" 2>/dev/null || true
# Build-time only: headers and module maps are never loaded at run time.
for d in Headers PrivateHeaders Modules; do
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework/$d" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/$d"
done
# Resources: Finder icon (fixed: watercolor) + the in-app icon choices. Must be in place before codesign.
# Sources live in App/logo/; an upscaled NAME@1024.png wins over NAME.png when present.
RES="$APP/Contents/Resources"; mkdir -p "$RES"
logo() { if [ -f "App/logo/$1@1024.png" ]; then echo "App/logo/$1@1024.png"; else echo "App/logo/$1.png"; fi; }
ICONTMP=$(mktemp -d)
swift App/icon-tool.swift "$(logo icon-watercolor)" "$ICONTMP/ink.png" 1024
swift App/icon-tool.swift "$(logo icon-glass)" "$ICONTMP/glass.png" 1024
cp "$ICONTMP/ink.png" "$RES/icon-ink.png"       # in-app icon choices (图标), full 1024 for Retina
cp "$ICONTMP/glass.png" "$RES/icon-glass.png"
# Finder icon: full-bleed square (no transparent margin, no own corners) so macOS 26+ applies its
# own mask instead of framing a legacy icon in a grey tile.
FULL="App/logo/icon-watercolor-fullbleed@1024.png"
SET="$ICONTMP/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$FULL" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$FULL" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$RES/AppIcon.icns"
cp "$RES/AppIcon.icns" App/AppIcon.icns     # keep the generated icon in the repo
rm -rf "$ICONTMP"
# About card art (scripts/make-about-pond.py).
cp App/about/about-pond-light.jpg App/about/about-pond-dark.jpg "$RES/"
# Break quotes (App/rest-quotes.json -> Resources/rest-quotes.json).
cp App/strings.json "$RES/strings.json"   # every UI string, all languages (see L10n.swift)
cp App/rest-quotes.json "$RES/rest-quotes.json" && echo "quotes: $(grep -c '"id"' App/rest-quotes.json)"
# Long-break backgrounds: release builds ship HEIC only, from App/backgrounds.
# The PNG originals are kept outside the repo. Regenerate a HEIC from a PNG with:
#   sips -s format heic -s formatOptions 80 in.png --out App/backgrounds/<name>.heic
# BG_DIR overrides the folder (any *.heic / *.png in it is copied; the check below rejects PNG).
BG_DIR="${BG_DIR:-App/backgrounds}"
if ls "$BG_DIR"/*.heic >/dev/null 2>&1 || ls "$BG_DIR"/*.png >/dev/null 2>&1; then
  mkdir -p "$RES/backgrounds"
  for f in "$BG_DIR"/*.heic "$BG_DIR"/*.png; do if [ -f "$f" ]; then cp "$f" "$RES/backgrounds/"; fi; done
  echo "backgrounds: $(ls "$RES/backgrounds" | wc -l | tr -d ' ') files from $BG_DIR"
else
  echo "backgrounds: none (using drawn scenery)"
fi
# Size guard: no PNG background may ship inside the app.
BAD=$(find "$APP" -path '*/backgrounds/*' -iname '*.png')
if [ -n "$BAD" ]; then
  echo "error: PNG backgrounds inside the app (ship HEIC only, see App/backgrounds):" >&2
  echo "$BAD" >&2
  exit 1
fi
# SwiftPM stamps the binary with sdk = deployment target (13.0), which makes AppKit
# run it in old-look compatibility mode. Record the real SDK so macOS 26+ uses Liquid Glass.
vtool -set-build-version macos 13.0 "$(xcrun --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/Pausa.tmp" "$APP/Contents/MacOS/Pausa" 2>/dev/null
mv "$APP/Contents/MacOS/Pausa.tmp" "$APP/Contents/MacOS/Pausa"
# Drop local symbols and the debug map (release crash logs still symbolicate exported names).
strip -x "$APP/Contents/MacOS/Pausa"
# Ad-hoc sign inside-out (no Developer ID). Sparkle's nested helpers need their own signature.
SP="$APP/Contents/Frameworks/Sparkle.framework"
if [ -e "$SP/Versions/B/XPCServices/Installer.xpc" ]; then codesign --force --sign - "$SP/Versions/B/XPCServices/Installer.xpc"; fi
if [ -e "$SP/Versions/B/XPCServices/Downloader.xpc" ]; then codesign --force --sign - --preserve-metadata=entitlements "$SP/Versions/B/XPCServices/Downloader.xpc"; fi
codesign --force --sign - "$SP/Versions/B/Autoupdate"
codesign --force --sign - "$SP/Versions/B/Updater.app"
codesign --force --sign - "$SP"
codesign --force --sign - "$APP"
echo "$APP"
