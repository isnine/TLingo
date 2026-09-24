#!/bin/bash
#
# extract-release-notes.sh
# Pull the section for a given version from CHANGELOG.md and emit a tiny
# styled HTML fragment that Sparkle can iframe into the update dialog.
#
# Usage:
#   ./ci_scripts/extract-release-notes.sh <version> <output-html>
#
# Section matching:
#   Looks for a heading like "## [3.2.0] - 2026-05-10" or "## [Unreleased]".
#   For non-tag dry runs, falls back to [Unreleased].
#

set -euo pipefail

VERSION="${1:?usage: extract-release-notes.sh <version> <output-html>}"
OUT="${2:?usage: extract-release-notes.sh <version> <output-html>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="${ROOT}/CHANGELOG.md"

if [ ! -f "$CHANGELOG" ]; then
    echo "CHANGELOG.md not found" >&2
    exit 1
fi

# Match "## [<version>]" first; fall back to "## [Unreleased]" if not found.
# Pattern is a literal heading prefix (awk index() compare, no regex escapes).
extract_section() {
    local heading="$1"
    awk -v hd="$heading" '
        BEGIN { in_section = 0 }
        /^## \[/ {
            if (in_section) exit
            if (index($0, hd) == 1) {
                in_section = 1
                next
            }
        }
        in_section { print }
    ' "$CHANGELOG"
}

SECTION=$(extract_section "## [${VERSION}]")
if [ -z "$(printf '%s' "$SECTION" | tr -d '[:space:]')" ]; then
    SECTION=$(extract_section "## [Unreleased]")
fi

if [ -z "$(printf '%s' "$SECTION" | tr -d '[:space:]')" ]; then
    SECTION="- See https://github.com/isnine/TLingo/releases for details."
fi

# Convert lightweight markdown → HTML.
# Handles: ### subheadings, - bullets, **bold**, `code`, continuation lines on
# previous bullets (lines indented 2+ spaces fold into the prior <li>).
HTML_BODY=$(printf '%s\n' "$SECTION" | awk '
    function inline(s) {
        # **bold**
        while (match(s, /\*\*[^*]+\*\*/)) {
            inner = substr(s, RSTART + 2, RLENGTH - 4)
            s = substr(s, 1, RSTART - 1) "<strong>" inner "</strong>" substr(s, RSTART + RLENGTH)
        }
        # `code`
        while (match(s, /`[^`]+`/)) {
            inner = substr(s, RSTART + 1, RLENGTH - 2)
            s = substr(s, 1, RSTART - 1) "<code>" inner "</code>" substr(s, RSTART + RLENGTH)
        }
        return s
    }
    function flush_list() { if (in_list) { print "</ul>"; in_list = 0 } }
    BEGIN { in_list = 0; pending = "" }
    /^### / {
        flush_list()
        sub(/^### /, "")
        print "<h2>" inline($0) "</h2>"
        next
    }
    /^- / {
        if (pending != "") { print pending "</li>"; pending = "" }
        if (!in_list) { print "<ul>"; in_list = 1 }
        sub(/^- /, "")
        pending = "<li>" inline($0)
        next
    }
    /^[[:space:]]+[^[:space:]]/ {
        # Continuation of previous bullet
        sub(/^[[:space:]]+/, " ")
        if (pending != "") {
            pending = pending inline($0)
        } else {
            print "<p>" inline($0) "</p>"
        }
        next
    }
    /^[[:space:]]*$/ {
        if (pending != "") { print pending "</li>"; pending = "" }
        flush_list()
        next
    }
    {
        if (pending != "") { print pending "</li>"; pending = "" }
        flush_list()
        print "<p>" inline($0) "</p>"
    }
    END {
        if (pending != "") print pending "</li>"
        flush_list()
    }
')

cat > "$OUT" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>TLingo ${VERSION}</title>
<style>
  body { font: 13px -apple-system, BlinkMacSystemFont, sans-serif; margin: 16px; color: #1d1d1f; }
  h1 { font-size: 16px; margin: 0 0 12px; }
  ul { padding-left: 20px; margin: 0; }
  li { margin: 4px 0; }
  p  { margin: 6px 0; }
  code { background: #f5f5f7; padding: 1px 4px; border-radius: 3px; }
  @media (prefers-color-scheme: dark) {
    body { background: #1e1e1e; color: #f5f5f7; }
    code { background: #2c2c2e; }
  }
</style>
</head>
<body>
<h1>What's New in ${VERSION}</h1>
${HTML_BODY}
</body>
</html>
EOF

echo "Wrote $OUT"
