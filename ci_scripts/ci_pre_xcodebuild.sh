#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/ci_scripts/generate-app-secrets.sh"

DIRECT_WORKFLOW_NAME="${DIRECT_RELEASE_WORKFLOW_NAME:-Direct Release}"

if [[ "${CI_WORKFLOW:-}" != "$DIRECT_WORKFLOW_NAME" ]]; then
    echo "Skipping Direct preparation for workflow: ${CI_WORKFLOW:-unknown}"
    exit 0
fi

if [[ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]]; then
    echo "Skipping Direct preparation for action: ${CI_XCODEBUILD_ACTION:-unknown}"
    exit 0
fi

PROJECT_FILE="$ROOT/ios/AITranslator.xcodeproj/project.pbxproj"
VERSION="$({
    sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' "$PROJECT_FILE"
} | sort -u)"

"$ROOT/ci_scripts/validate-direct-release.sh" "$VERSION"

BUILD_NUMBER="$(( $(git -C "$ROOT" rev-list --count HEAD) + 1000 ))"
sed -i '' -E \
    "s/(CURRENT_PROJECT_VERSION = )[0-9]+;/\\1$BUILD_NUMBER;/g" \
    "$PROJECT_FILE"

UPDATED_BUILD_NUMBERS="$({
    sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);/\1/p' "$PROJECT_FILE"
} | sort -u)"

if [[ "$UPDATED_BUILD_NUMBERS" != "$BUILD_NUMBER" ]]; then
    echo "Failed to apply Direct build number $BUILD_NUMBER: found $UPDATED_BUILD_NUMBERS" >&2
    exit 1
fi

echo "Prepared Direct archive: version=$VERSION build=$BUILD_NUMBER"
