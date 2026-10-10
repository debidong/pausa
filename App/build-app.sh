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
codesign --force --sign - "$APP"
echo "$APP"
