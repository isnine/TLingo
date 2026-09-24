#!/bin/bash

set -euo pipefail

DIRECT_WORKFLOW_NAME="${DIRECT_RELEASE_WORKFLOW_NAME:-Direct Release}"

if [[ "${CI_WORKFLOW:-}" != "$DIRECT_WORKFLOW_NAME" ]]; then
    echo "Skipping Direct publishing for workflow: ${CI_WORKFLOW:-unknown}"
    exit 0
fi

if [[ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]]; then
    echo "Skipping Direct publishing for action: ${CI_XCODEBUILD_ACTION:-unknown}"
    exit 0
fi

if [[ "${CI_XCODEBUILD_EXIT_CODE:-1}" != "0" ]]; then
    echo "Direct archive failed; publishing is disabled" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT/ios/AITranslator.xcodeproj/project.pbxproj"
VERSION="$({
    sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' "$PROJECT_FILE"
} | sort -u)"
BUILD_DIR="$ROOT/build/direct-release"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/TLingo.app"
DMG_PATH="$BUILD_DIR/TLingo.dmg"
R2_BUCKET="${DIRECT_RELEASE_R2_BUCKET:-tlingo-releases}"
APPCAST_BASE_URL="${APPCAST_BASE_URL:-https://updates.tlingo.zanderwang.com}"

"$ROOT/ci_scripts/validate-direct-release.sh" "$VERSION"

for name in CI_ARCHIVE_PATH DEV_ID_CERT_P12 DEV_ID_CERT_PASSWORD KEYCHAIN_PASSWORD ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_KEY_P8_B64; do
    if [[ -z "${!name:-}" ]]; then
        echo "Required Direct release variable is missing: $name" >&2
        exit 1
    fi
done

rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_DIR"

KEYCHAIN_PATH="$BUILD_DIR/direct-release.keychain-db"
CERTIFICATE_PATH="$BUILD_DIR/developer-id.p12"
NOTARY_KEY_PATH="$BUILD_DIR/AuthKey_${ASC_API_KEY_ID}.p8"
ORIGINAL_KEYCHAINS=()
while IFS= read -r keychain; do
    keychain="${keychain//\"/}"
    keychain="${keychain#"${keychain%%[![:space:]]*}"}"
    if [[ -n "$keychain" ]]; then
        ORIGINAL_KEYCHAINS+=("$keychain")
    fi
done < <(security list-keychains -d user)

cleanup() {
    rm -f "$CERTIFICATE_PATH" "$NOTARY_KEY_PATH"
    if [[ -f "$KEYCHAIN_PATH" ]]; then
        if ((${#ORIGINAL_KEYCHAINS[@]} > 0)); then
            security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" || true
        fi
        security delete-keychain "$KEYCHAIN_PATH" || true
    fi
    if [[ -n "${VERIFY_DIR:-}" && -d "$VERIFY_DIR" ]]; then
        rm -rf "$VERIFY_DIR"
    fi
}
trap cleanup EXIT

printf '%s' "$DEV_ID_CERT_P12" | base64 --decode > "$CERTIFICATE_PATH"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" \
    -k "$KEYCHAIN_PATH" \
    -P "$DEV_ID_CERT_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/productbuild
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH" "${ORIGINAL_KEYCHAINS[@]}"
rm -f "$CERTIFICATE_PATH"

xcodebuild -exportArchive \
    -archivePath "$CI_ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$ROOT/ios/Configuration/ExportOptions-DeveloperID.plist"

if [[ ! -d "$APP_PATH" ]]; then
    echo "Developer ID export did not produce $APP_PATH" >&2
    exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"

if [[ "$APP_VERSION" != "$VERSION" ]]; then
    echo "Archived app version mismatch: expected $VERSION, found $APP_VERSION" >&2
    exit 1
fi

EXPECTED_BUILD="$(( $(git -C "$ROOT" rev-list --count HEAD) + 1000 ))"
if [[ "$APP_BUILD" != "$EXPECTED_BUILD" ]]; then
    echo "Archived app build mismatch: expected $EXPECTED_BUILD, found $APP_BUILD" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

printf '%s' "$ASC_API_KEY_P8_B64" | base64 --decode > "$NOTARY_KEY_PATH"
chmod 600 "$NOTARY_KEY_PATH"
ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/TLingo.zip"
xcrun notarytool submit "$BUILD_DIR/TLingo.zip" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$ASC_API_KEY_ID" \
    --issuer "$ASC_API_ISSUER_ID" \
    --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
rm -f "$NOTARY_KEY_PATH"

if [[ ! "${CI_TAG:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Verified Direct archive without a release tag; nothing was published"
    exit 0
fi

DMG_PUBLIC_NAME="TLingo-$CI_TAG.dmg"
RELEASE_NOTES_NAME="$CI_TAG.html"

for name in SPARKLE_PRIVATE_KEY CLOUDFLARE_API_TOKEN; do
    if [[ -z "${!name:-}" ]]; then
        echo "Required Direct release variable is missing: $name" >&2
        exit 1
    fi
done

DMG_ROOT="$BUILD_DIR/dmg-root"
mkdir -p "$DMG_ROOT"
ditto "$APP_PATH" "$DMG_ROOT/TLingo.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
    -volname "TLingo" \
    -srcfolder "$DMG_ROOT" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

"$ROOT/ci_scripts/extract-release-notes.sh" "$VERSION" "$BUILD_DIR/release-notes.html"

SPARKLE_SEARCH_ROOT="${CI_DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData}"
SIGN_UPDATE="$(find "$SPARKLE_SEARCH_ROOT" -path '*/artifacts/sparkle/*/bin/sign_update' -type f -print -quit 2>/dev/null || true)"
if [[ -z "$SIGN_UPDATE" ]]; then
    echo "Sparkle sign_update was not found under $SPARKLE_SEARCH_ROOT" >&2
    exit 1
fi

SIGN_UPDATE_DIR="$(dirname "$SIGN_UPDATE")"
export PATH="$SIGN_UPDATE_DIR:$PATH"
export APPCAST_BASE_URL
export DMG_PUBLIC_NAME
export RELEASE_NOTES_URL="$APPCAST_BASE_URL/release-notes/$RELEASE_NOTES_NAME"
"$ROOT/ci_scripts/generate-appcast.sh" "$DMG_PATH"

if ! command -v npx >/dev/null 2>&1; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew install node
fi

WRANGLER=(npx --yes wrangler@4 r2 object)
export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is required}"

"${WRANGLER[@]}" put "$R2_BUCKET/$DMG_PUBLIC_NAME" --file="$DMG_PATH" --remote
"${WRANGLER[@]}" put "$R2_BUCKET/release-notes/$RELEASE_NOTES_NAME" \
    --file="$BUILD_DIR/release-notes.html" \
    --remote \
    --content-type=text/html
"${WRANGLER[@]}" put "$R2_BUCKET/appcast.xml" \
    --file="$BUILD_DIR/appcast.xml" \
    --remote \
    --content-type=application/rss+xml

VERIFY_DIR="$(mktemp -d)"
"${WRANGLER[@]}" get "$R2_BUCKET/$DMG_PUBLIC_NAME" --file="$VERIFY_DIR/TLingo.dmg" --remote
"${WRANGLER[@]}" get "$R2_BUCKET/release-notes/$RELEASE_NOTES_NAME" --file="$VERIFY_DIR/release-notes.html" --remote
"${WRANGLER[@]}" get "$R2_BUCKET/appcast.xml" --file="$VERIFY_DIR/appcast.xml" --remote

cmp "$DMG_PATH" "$VERIFY_DIR/TLingo.dmg"
cmp "$BUILD_DIR/release-notes.html" "$VERIFY_DIR/release-notes.html"
cmp "$BUILD_DIR/appcast.xml" "$VERIFY_DIR/appcast.xml"

echo "Published Direct release: version=$APP_VERSION build=$APP_BUILD"
