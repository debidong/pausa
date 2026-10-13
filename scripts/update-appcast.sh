#!/bin/sh
# Sign an archive with EdDSA and add it as the newest <item> in an appcast.xml.
# Usage: scripts/update-appcast.sh ARCHIVE VERSION BUILD DOWNLOAD_URL APPCAST_XML
# Private key: env SPARKLE_ED_PRIVATE_KEY (CI) or the login Keychain (local Mac).
set -eu
[ $# -eq 5 ] || { sed -n '2,4p' "$0" >&2; exit 2; }
ARCHIVE=$1 VERSION=$2 BUILD=$3 URL=$4 APPCAST=$5
BIN=$("$(dirname "$0")/sparkle-tools.sh")
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
  SIG=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$BIN/sign_update" --ed-key-file - "$ARCHIVE")
else
  SIG=$("$BIN/sign_update" "$ARCHIVE")
fi
# SIG looks like: sparkle:edSignature="..." length="..."
MINOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$(dirname "$0")/../App/Info.plist" 2>/dev/null || echo 13.0)
DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
ITEM="    <item>
      <title>$VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <enclosure url=\"$URL\" type=\"application/octet-stream\" $SIG/>
    </item>"
if [ ! -f "$APPCAST" ]; then
  cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Pausa</title>
  </channel>
</rss>
XML
fi
ITEM="$ITEM" python3 - "$APPCAST" <<'PY'
import os, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
marker = "</title>\n"  # insert right after the channel title, newest first
i = s.index(marker) + len(marker)
open(p, "w", encoding="utf-8").write(s[:i] + os.environ["ITEM"] + "\n" + s[i:])
PY
echo "appcast: added $VERSION ($BUILD) to $APPCAST"
