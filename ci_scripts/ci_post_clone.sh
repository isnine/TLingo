#!/bin/bash
#
# ci_post_clone.sh
# Xcode Cloud post-clone script for AITranslator.
#
# Generates the gitignored AppSecrets.swift from Xcode Cloud TLINGO_*
# secret environment variables.

set -e

"$(dirname "${BASH_SOURCE[0]}")/generate-app-secrets.sh"

defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

if [[ "${CI_WORKFLOW:-}" == "${DIRECT_RELEASE_WORKFLOW_NAME:-Direct Release}" ]]; then
    REPOSITORY_PATH="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    if [[ "$(git -C "$REPOSITORY_PATH" rev-parse --is-shallow-repository)" == "true" ]]; then
        git -C "$REPOSITORY_PATH" fetch --unshallow --tags origin
    else
        git -C "$REPOSITORY_PATH" fetch --tags origin
    fi
fi

echo "================================================"
echo "  Xcode Cloud Post-Clone"
echo "================================================"
echo "Repository: ${CI_PRIMARY_REPOSITORY_PATH:-?}"
echo "Workflow:   ${CI_WORKFLOW:-?}"
echo "Branch:     ${CI_BRANCH:-?}"
echo "Commit:     ${CI_COMMIT:-?}"
echo "Direct full-history preparation completed when required"
