#!/bin/sh
# Sign an archive with EdDSA and add (or replace) it as the newest <item> in an appcast.xml.
# Usage: scripts/update-appcast.sh ARCHIVE VERSION BUILD DOWNLOAD_URL APPCAST_XML
# Private key: env SPARKLE_ED_PRIVATE_KEY (CI) or the login Keychain (local Mac).
set -eu
[ $# -eq 5 ] || { sed -n '2,4p' "$0" >&2; exit 2; }
ARCHIVE=$1 VERSION=$2 BUILD=$3 URL=$4 APPCAST=$5

[ -f "$ARCHIVE" ] || { echo "error: archive not found: $ARCHIVE" >&2; exit 1; }
BIN=$("$(dirname "$0")/sparkle-tools.sh")
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
  SIG=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$BIN/sign_update" --ed-key-file - "$ARCHIVE")
else
  SIG=$("$BIN/sign_update" "$ARCHIVE")
fi
# SIG looks like: sparkle:edSignature="..." length="..."
MINOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$(dirname "$0")/../App/Info.plist" 2>/dev/null || echo 13.0)
DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')

SIG="$SIG" VERSION="$VERSION" BUILD="$BUILD" URL="$URL" MINOS="$MINOS" DATE="$DATE" \
python3 - "$APPCAST" <<'PY'
import os
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

appcast_path = sys.argv[1]
sig_raw = os.environ["SIG"].strip()
version = os.environ["VERSION"].strip()
build = os.environ["BUILD"].strip()
url = os.environ["URL"].strip()
minos = os.environ["MINOS"].strip()
pub_date = os.environ["DATE"].strip()

m_sig = re.search(r'sparkle:edSignature="([^"]+)"', sig_raw)
m_len = re.search(r'length="([0-9]+)"', sig_raw)
if not m_sig or not m_len:
    sys.exit(f"error: unexpected sign_update output: {sig_raw!r}")
ed_sig, byte_len = m_sig.group(1), m_len.group(1)

if os.path.exists(appcast_path):
    tree = ET.parse(appcast_path)
    root = tree.getroot()
else:
    root = ET.Element("rss", {"version": "2.0"})
    ch = ET.SubElement(root, "channel")
    t = ET.SubElement(ch, "title")
    t.text = "Pausa"
    tree = ET.ElementTree(root)

channel = root.find("channel")
if channel is None:
    sys.exit("error: appcast.xml has no <channel> element")

q_ver = f"{{{SPARKLE_NS}}}version"
q_short = f"{{{SPARKLE_NS}}}shortVersionString"
q_minos = f"{{{SPARKLE_NS}}}minimumSystemVersion"
q_edsig = f"{{{SPARKLE_NS}}}edSignature"

# Remove any existing <item> with the same version or build so re-runs stay idempotent.
for existing in list(channel.findall("item")):
    ev = (existing.findtext(q_ver) or "").strip()
    es = (existing.findtext(q_short) or "").strip()
    if ev == build or es == version:
        channel.remove(existing)

item = ET.Element("item")
ET.SubElement(item, "title").text = version
ET.SubElement(item, "pubDate").text = pub_date
ET.SubElement(item, q_ver).text = build
ET.SubElement(item, q_short).text = version
ET.SubElement(item, q_minos).text = minos
enclosure = ET.SubElement(item, "enclosure")
enclosure.set("url", url)
enclosure.set("type", "application/octet-stream")
enclosure.set(q_edsig, ed_sig)
enclosure.set("length", byte_len)

# Insert right after <title> inside <channel> (newest first).
children = list(channel)
insert_idx = 0
for idx, child in enumerate(children):
    if child.tag == "title":
        insert_idx = idx + 1
        break
channel.insert(insert_idx, item)

ET.indent(tree, space="  ")
tmp_path = appcast_path + ".tmp"
tree.write(tmp_path, encoding="utf-8", xml_declaration=True)
with open(tmp_path, "rb") as fh:
    body = fh.read()
# Normalize XML header quote style and trailing newline, then re-parse to validate.
body = body.replace(b"<?xml version='1.0' encoding='utf-8'?>", b'<?xml version="1.0" encoding="utf-8"?>', 1)
if not body.endswith(b"\n"):
    body += b"\n"
ET.fromstring(body)
with open(tmp_path, "wb") as fh:
    fh.write(body)
os.replace(tmp_path, appcast_path)
PY
echo "appcast: added $VERSION ($BUILD) to $APPCAST"
