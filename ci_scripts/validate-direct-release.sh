#!/bin/bash

set -euo pipefail

VERSION="${1:?usage: validate-direct-release.sh <version>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT/ios/AITranslator.xcodeproj/project.pbxproj"
CHANGELOG_FILE="$ROOT/CHANGELOG.md"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid Direct release version: $VERSION" >&2
    exit 1
fi

if [[ ! -f "$PROJECT_FILE" || ! -f "$CHANGELOG_FILE" ]]; then
    echo "Direct release inputs are missing" >&2
    exit 1
fi

MARKETING_VERSIONS="$({
    sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' "$PROJECT_FILE"
} | sort -u)"

if [[ "$MARKETING_VERSIONS" != "$VERSION" ]]; then
    echo "MARKETING_VERSION mismatch: expected $VERSION, found: $MARKETING_VERSIONS" >&2
    exit 1
fi

if ! grep -qE "^## \[$VERSION\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$CHANGELOG_FILE"; then
    echo "CHANGELOG.md has no dated section for $VERSION" >&2
    exit 1
fi

CHANGELOG_SECTION="$(awk -v heading="## [$VERSION]" '
    /^## \[/ {
        if (active) exit
        active = index($0, heading) == 1
        next
    }
    active { print }
' "$CHANGELOG_FILE")"

if ! grep -qE '^- ' <<<"$CHANGELOG_SECTION"; then
    echo "CHANGELOG.md section for $VERSION has no release notes" >&2
    exit 1
fi

if [[ -n "${CI_TAG:-}" && "$CI_TAG" != "v$VERSION" ]]; then
    echo "Tag/version mismatch: tag is $CI_TAG, app version is $VERSION" >&2
    exit 1
fi

BUILD_NUMBER="$(( $(git -C "$ROOT" rev-list --count HEAD) + 1000 ))"
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Unable to compute the Direct build number" >&2
    exit 1
fi

if [[ -n "${CI_TAG:-}" ]]; then
    APPCAST_URL="${APPCAST_BASE_URL:-https://updates.tlingo.zanderwang.com}/appcast.xml"
    CURRENT_BUILD="$(curl --fail --silent --show-error "$APPCAST_URL" |
        sed -nE 's|.*<sparkle:version>([0-9]+)</sparkle:version>.*|\1|p' |
        head -1)"

    if [[ ! "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
        echo "Unable to read the current Sparkle build number from $APPCAST_URL" >&2
        exit 1
    fi

    if ((BUILD_NUMBER <= CURRENT_BUILD)); then
        echo "Direct build number $BUILD_NUMBER must be greater than published build $CURRENT_BUILD" >&2
        exit 1
    fi
fi

echo "Direct release validation passed: version=$VERSION build=$BUILD_NUMBER"
