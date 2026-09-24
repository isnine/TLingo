# TLingo

TLingo is a SwiftUI translation app for iOS and macOS. It supports system translation, LLM providers, realtime captions, text-selection translation, App Store subscriptions, and a Direct (Developer ID + Sparkle) macOS build.

## Download

| Channel | Platform | Updates |
| --- | --- | --- |
| [App Store](https://apps.apple.com/app/id6754217103) | iOS, iPadOS, macOS | App Store |
| [Direct](https://tlingo.zanderwang.com/download) | macOS | Sparkle |

## Requirements

- iOS 26.0 or macOS 26.0
- Xcode 26

## Build

```bash
git clone https://github.com/isnine/TLingo.git
cd TLingo
./ci_scripts/generate-app-secrets.sh
open ios/AITranslator.xcodeproj
```

`generate-app-secrets.sh` writes the gitignored `ios/ShareCore/Configuration/AppSecrets.swift`. Without `TLINGO_*` environment variables it writes placeholders: the app builds and runs, but the hosted TLingo cloud models, Direct sign-in, and website purchase restore are unavailable. System translation and your own LLM providers still work. Replace `DEVELOPMENT_TEAM` in `ios/Configuration/*.xcconfig` with your own team to sign.

Main schemes:

- `TLingo`
- `TLingo-Direct`
- `TLingoTranslation`
- `TLingoUITests`

## Repository

```text
ios/          Apple app, shared framework, and extensions
ci_scripts/   Xcode Cloud and Direct release automation
docs/         Client architecture, contracts, and workflows
```

The cloud Worker and Web frontend are maintained separately and are not part of this repository.

## Verification

Build and test commands are documented in [`docs/verification.md`](docs/verification.md).

## Documentation

- [`docs/README.md`](docs/README.md)
- [`docs/architecture/ios-overview.md`](docs/architecture/ios-overview.md)
- [`docs/architecture/client-contracts.md`](docs/architecture/client-contracts.md)

## License

TLingo's original source code is licensed under the GNU General Public License
version 3 only (`GPL-3.0-only`). See [`LICENSE`](LICENSE).

Third-party dependencies and materials remain subject to their respective
licenses.
