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

echo "================================================"
echo "  Xcode Cloud Post-Clone"
echo "================================================"
echo "Repository: ${CI_PRIMARY_REPOSITORY_PATH:-?}"
echo "Workflow:   ${CI_WORKFLOW:-?}"
echo "Branch:     ${CI_BRANCH:-?}"
echo "Commit:     ${CI_COMMIT:-?}"
