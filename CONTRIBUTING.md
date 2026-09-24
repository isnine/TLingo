# Contributing To TLingo

## Setup

```bash
git clone https://github.com/isnine/TLingo.git
cd TLingo
./ci_scripts/generate-app-secrets.sh
open ios/AITranslator.xcodeproj
```

Read [`AGENTS.md`](AGENTS.md) and [`docs/README.md`](docs/README.md) before changing architecture or workflows. Placeholder secrets disable the hosted cloud features; see [`README.md`](README.md).

## Development

- Keep changes focused and follow existing module ownership.
- Do not add a branch, dependency, abstraction, or secret path without a concrete need.
- Use filesystem-synchronized Xcode groups; adding a Swift file normally does not require editing `project.pbxproj`.
- Update canonical docs when a contract, target, or verification command changes.

## Validation

Follow [`docs/verification.md`](docs/verification.md). Typical checks:

```bash
git diff --check
swiftformat --lint <touched-swift-files>
swiftlint lint <touched-swift-files>
```

Use the relevant `TLingo` or `TLingo-Direct` build for Apple changes.

## Commits

Commit messages use:

```text
[Developer] Tooling or configuration
[Fixed] Bug fix
[Added] Feature
[Improved] Enhancement
[Removed] Removal
```

Do not commit generated build output, `AppSecrets.swift`, or other secrets.
