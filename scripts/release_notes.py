#!/usr/bin/env python3
"""Generate in-app release notes from CHANGELOG.md.

Usage:
  scripts/release_notes.py draft   Print commits since the last version bump as a CHANGELOG section.
  scripts/release_notes.py build   Write ReleaseNotes.json and sync ReleaseNotes.xcstrings from CHANGELOG.md.

Commit subjects use `[Added]`, `[Improved]`, `[Fixed]`, or `[Chore]`, optionally followed by a
platform tag `[iOS]` or `[Mac]` (no tag means both). CHANGELOG items keep the platform tag as a
prefix, e.g. `- [Mac] Kept global shortcuts separate per app.` Only the Added, Improved, and Fixed
sections ship in the app.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"
PBXPROJ = ROOT / "ios/AITranslator.xcodeproj/project.pbxproj"
RESOURCES = ROOT / "ios/ShareCore/Resources"
NOTES_JSON = RESOURCES / "ReleaseNotes.json"
CATALOG = RESOURCES / "ReleaseNotes.xcstrings"

# Older sections predate platform tags; they still count as missed versions but show no items.
FIRST_ITEMIZED_VERSION = "5.5.9"
KINDS = {"Added": "added", "Improved": "improved", "Fixed": "fixed"}
PLATFORMS = {"iOS": "ios", "Mac": "macos"}
SECTION = re.compile(r"^## \[(\d+(?:\.\d+)*)\]")
COMMIT = re.compile(r"^\[(\w+)\](?:\s*\[(iOS|Mac)\])?\s*(.+)$")


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout


def marketing_version(pbxproj_text):
    versions = set(re.findall(r"MARKETING_VERSION = ([0-9.]+);", pbxproj_text))
    versions.discard("1.0.0")  # TLingoHelper keeps its own version.
    return max(versions, key=version_key) if versions else None


def last_bump_commit():
    """Newest commit that changed the app's MARKETING_VERSION value."""
    commits = git("log", "-G", "MARKETING_VERSION = ", "--format=%H", "--", str(PBXPROJ.relative_to(ROOT))).split()
    for commit in commits:
        after = marketing_version(git("show", f"{commit}:{PBXPROJ.relative_to(ROOT)}"))
        try:
            before = marketing_version(git("show", f"{commit}^:{PBXPROJ.relative_to(ROOT)}"))
        except subprocess.CalledProcessError:
            return commit
        if after != before:
            return commit
    return None


def draft():
    base = last_bump_commit()
    if base is None:
        sys.exit("No MARKETING_VERSION change found.")
    subjects = git("log", "--reverse", "--format=%s", f"{base}..HEAD").splitlines()
    sections = {name: [] for name in KINDS}
    skipped = []
    for subject in subjects:
        match = COMMIT.match(subject)
        if not match or match.group(1) not in KINDS:
            if not (match and match.group(1) == "Chore"):
                skipped.append(subject)
            continue
        tag = f"[{match.group(2)}] " if match.group(2) else ""
        sections[match.group(1)].append(f"- {tag}{match.group(3)}")
    print(f"<!-- since {git('log', '-1', '--format=%h %s', base).strip()} -->")
    for name, lines in sections.items():
        if lines:
            print(f"\n### {name}\n")
            print("\n".join(lines))
    if skipped:
        print("\n<!-- skipped, check for user-facing changes:\n" + "\n".join(skipped) + "\n-->")


def parse_changelog():
    releases = []
    current = None
    kind = None
    for line in CHANGELOG.read_text().splitlines():
        if match := SECTION.match(line):
            current = {"version": match.group(1), "items": []}
            releases.append(current)
            kind = None
        elif line.startswith("## "):
            current = None
        elif line.startswith("### ") and current is not None:
            kind = KINDS.get(line[4:].strip())
        elif line.startswith("  ") and line.strip() and current is not None and current["items"] and kind is not None:
            # Wrapped continuation of the previous item.
            item = current["items"][-1]
            item["text"] = f"{item['text']} {line.strip()}"
        elif line.startswith("- ") and current is not None and kind is not None:
            if version_key(current["version"]) < version_key(FIRST_ITEMIZED_VERSION):
                continue
            text = line[2:].strip()
            item = {"kind": kind}
            if tag := re.match(r"^\[(iOS|Mac)\]\s*", text):
                item["platforms"] = [PLATFORMS[tag.group(1)]]
                text = text[tag.end():]
            item["text"] = text
            current["items"].append(item)
    return releases


def build():
    releases = parse_changelog()
    NOTES_JSON.write_text(json.dumps({"releases": releases}, indent=2, ensure_ascii=False) + "\n")

    texts = [item["text"] for release in releases for item in release["items"]]
    catalog = json.loads(CATALOG.read_text()) if CATALOG.exists() else {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    strings = catalog["strings"]
    # Only manual entries belong to the generator; strings extracted from code stay untouched.
    for key in [key for key, entry in strings.items() if entry.get("extractionState") == "manual" and key not in texts]:
        del strings[key]
    for text in texts:
        strings.setdefault(text, {"extractionState": "manual"})
    catalog["strings"] = dict(sorted(strings.items()))
    CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", " : ")) + "\n")
    print(f"{len(releases)} releases, {len(texts)} items -> {NOTES_JSON.relative_to(ROOT)}, {CATALOG.relative_to(ROOT)}")


if __name__ == "__main__":
    commands = {"draft": draft, "build": build}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        sys.exit(__doc__)
    commands[sys.argv[1]]()
