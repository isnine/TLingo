#!/bin/bash
#
# generate-appcast.sh
# Build a Sparkle appcast.xml entry for the freshly-built DMG.
#
# Inputs:
#   $1                       Path to the DMG (e.g. build/TLingo.dmg)
#   $SPARKLE_PRIVATE_KEY     EdDSA private key (raw, base64 or path) used by
#                            Sparkle's `sign_update` tool.
#   $APPCAST_BASE_URL        Public URL prefix for downloads
#                            (default: https://updates.tlingo.zanderwang.com)
#
# Output:
#   build/appcast.xml
#
# Notes:
#   - Requires Sparkle's `sign_update` and `generate_appcast` to be on PATH.
#     Install via SPM artifact bundle or `brew install --cask sparkle`.
#   - Version is read from the .app's Info.plist (CFBundleShortVersionString
#     and CFBundleVersion).

set -euo pipefail

DMG_PATH="${1:?usage: generate-appcast.sh <dmg-path>}"
APPCAST_BASE_URL="${APPCAST_BASE_URL:-https://updates.tlingo.zanderwang.com}"
# Public-facing filename. CI sets DMG_PUBLIC_NAME so the appcast URL matches
# what was uploaded to R2 (e.g. TLingo-v3.2.0.dmg). Falls back to
# the local basename for ad-hoc local runs.
DMG_PUBLIC_NAME="${DMG_PUBLIC_NAME:-$(basename "$DMG_PATH")}"

if [ ! -f "$DMG_PATH" ]; then
    echo "DMG not found: $DMG_PATH" >&2
    exit 1
fi

if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
    echo "SPARKLE_PRIVATE_KEY is not set" >&2
    exit 1
fi

OUT_DIR="$(dirname "$DMG_PATH")"
APP_PATH="${OUT_DIR}/export/TLingo.app"

if [ ! -d "$APP_PATH" ]; then
    echo "App not found at expected path: $APP_PATH" >&2
    exit 1
fi

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_PATH/Contents/Info.plist")"
DMG_NAME="${DMG_PUBLIC_NAME}"
DMG_SIZE="$(stat -f%z "$DMG_PATH")"
PUB_DATE="$(LC_TIME=en_US date -u +"%a, %d %b %Y %H:%M:%S +0000")"

# Persist the private key so sign_update can read it from a file.
KEY_FILE="$(mktemp)"
trap 'rm -f "$KEY_FILE"' EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"

EDDSA_SIG="$(sign_update -f "$KEY_FILE" "$DMG_PATH" | awk -F'"' '/sparkle:edSignature/ {print $2}')"

if [ -z "$EDDSA_SIG" ]; then
    echo "Failed to compute EdDSA signature" >&2
    exit 1
fi

APPCAST_PATH="${OUT_DIR}/appcast.xml"

# Build a sparkle:releaseNotesLink line if RELEASE_NOTES_URL is provided.
# (CI uploads the HTML to R2 before this script runs.)
RELEASE_NOTES_LINE=""
if [ -n "${RELEASE_NOTES_URL:-}" ]; then
    RELEASE_NOTES_LINE="            <sparkle:releaseNotesLink>${RELEASE_NOTES_URL}</sparkle:releaseNotesLink>"
fi

cat > "$APPCAST_PATH" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>TLingo (Direct)</title>
        <link>${APPCAST_BASE_URL}/appcast.xml</link>
        <description>Most recent updates to TLingo.</description>
        <language>en</language>
        <item>
            <title>Version ${SHORT_VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
${RELEASE_NOTES_LINE}
            <enclosure
                url="${APPCAST_BASE_URL}/${DMG_NAME}"
                length="${DMG_SIZE}"
                type="application/octet-stream"
                sparkle:edSignature="${EDDSA_SIG}" />
        </item>
    </channel>
</rss>
EOF

echo "Wrote $APPCAST_PATH"
