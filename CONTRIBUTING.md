# Contributing To TLingo

## Setup

Build setup is in [`README.md`](README.md). Read [`AGENTS.md`](AGENTS.md) and [`docs/README.md`](docs/README.md) before changing architecture or workflows. Placeholder secrets disable the hosted cloud features.

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

Use the `TLingo` scheme for the relevant Apple platform. For Helper changes, use
the additional gates in `docs/verification.md`.

## Commits

Commit messages use:

Subjects start with `[Added]`, `[Improved]`, `[Fixed]`, or `[Chore]`, optionally followed by `[iOS]`, `[Mac]`, or `[Both]`. See [`AGENTS.md`](AGENTS.md) for release-note rules.

Do not commit generated build output, `AppSecrets.swift`, or other secrets.
