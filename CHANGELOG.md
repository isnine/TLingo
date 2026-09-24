# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.8.3] - 2026-09-19

### Improved

- Added Tab as a keyboard shortcut to swap source and target languages in the main app and Quick Translator.

## [3.8.2] - 2026-09-19

### Added

- Added GPT-5.6 for Premium translation.
- Added Microsoft Translate as a direct translation option.

### Improved

- Refreshed cloud model choices and model labels.
- Updated compatibility with Xcode 27 and refined iOS navigation.
- Improved macOS language search, keyboard selection, and diagnostic log exports.

### Fixed

- Centered the audio playback button in the macOS text-selection popup.
- Kept configuration changes in sync after repeated saves.
- Prevented delayed sign-in responses from restoring a previous account.
- Improved subscription synchronization when billing data is incomplete.

## [3.8.1] - 2026-09-14

### Improved

- Updated compatibility with Xcode 27 and refined the iOS 27 Chat tab.
- Adopted native navigation controls for iOS text and realtime translation.
- Improved macOS language search and keyboard selection.
- Added a local diagnostic log viewer and improved feedback log exports.

## [3.8.0] - 2026-09-06

### Added

- Added Microsoft Translate as a direct translation option.

### Improved

- Updated cloud model choices and made model labels easier to read.

### Fixed

- Kept configuration changes in sync after repeated saves.
- Prevented delayed sign-in responses from restoring an old account after sign-out or account changes.
- Improved subscription synchronization when billing data is incomplete.

## [3.7.9] - 2026-08-30

### Improved

- Simplified realtime translation setup by removing retired Azure-only recognition and translation options.
- Refined macOS onboarding and Direct update controls.

### Fixed

- Migrated saved realtime configurations from retired Azure options to supported defaults.

## [3.7.8] - 2026-08-26

### Added

- Added an option to replace selected text with its translation in supported macOS apps.

### Improved

- Refreshed translation onboarding copy and language-switching behavior.

## [3.7.7] - 2026-08-22

### Added

- Added Apple Private Cloud Compute as an Apple Intelligence model option.
- Added a guided macOS onboarding flow with text-selection trials and Premium setup.

### Improved

- Streamlined macOS permission setup and refined selected-text translation controls.
- Made Apple Intelligence model availability clearer.

### Fixed

- Restored stable MOSS speaker labels in realtime history.

## [3.7.6] - 2026-08-21

### Fixed

- Preserved Direct membership through OAuth refresh failures until the saved membership expiry.

## [3.7.5] - 2026-08-21

### Improved

- Refined macOS onboarding layout and permission setup.
- Clarified Grammar Check's final translation in the app language.

### Fixed

- Persisted the text-selection popup position and size.

## [3.7.4] - 2026-08-19

### Improved

- Streamlined macOS Accessibility and screen recording permission setup.

### Fixed

- Restored stable speaker names for MOSS realtime history records.

## [3.7.3] - 2026-08-01

### Fixed

- Hardened model catalog validation.
- Prevented corrupted realtime history data from deleting audio recordings.

## [3.7.2] - 2026-07-27

### Fixed

- Fixed Direct release builds that validate the MLX package plug-in.

## [3.7.1] - 2026-07-26

### Added

- Added realtime translation latency visibility.

### Improved

- Expanded realtime recognition and audio workflows.
- Used the app language for analysis and localized latency presentation.
- Refined Apple Translate route selection.

### Fixed

- Hardened realtime translation pipeline reliability.

## [3.7.0] - 2026-07-21

### Added

- Added speaker-aware realtime history audio reconstruction on supported Apple
  Silicon Macs.

### Improved

- Reduced the iOS app size by excluding macOS-only speech dependencies.
- Added keyboard playback control for realtime history audio.

### Fixed

- Allowed supported Apple Translate language pairs to start before their
  language packs finish downloading.
- Limited MOSS history reconstruction to supported Apple Silicon Macs.

## [3.6.0] - 2026-07-17

### Added

- Added a dedicated Chat tab with saved conversation history.
- Added safer conversation replacement while a response is streaming.

### Improved

- Improved conversation history snapshots, model selection, and streamed
  reasoning/content presentation.
- Improved model refresh, entitlement handling, localization, and support copy.

## [3.5.4] - 2026-07-15

### Improved

- Refined history chat presentation, model selection, and toolbar placement.

## [3.5.3] - 2026-07-14

### Fixed

- Prevented the macOS app from repeatedly requesting access to data from other
  apps when loading the model cache.

## [3.5.2] - 2026-07-14

### Fixed

- Fixed production APNs configuration for push notifications.

## [3.5.1] - 2026-07-14

### Added

- Added offline translation with Apple Translate and supported on-device Apple
  Foundation Models.
- Added Polish and Malay localization coverage.

### Improved

- Improved streamed Markdown rendering for conversations.
- Refreshed app and marketing localization coverage.

### Fixed

- Improved realtime session stability by keeping websocket tasks explicitly
  owned.

## [3.5.0] - 2026-07-13

### Added

- Added generated titles and per-track copy actions for realtime history.
- Added a locale-aware iOS App Store screenshot pipeline for all supported
  languages, including the connected editorial screenshot editor.

### Improved

- Preserved realtime history titles during autosave merges.
- Kept realtime translation lanes recoverable after a successful translation
  when a later language-pack error occurs.
- Refined realtime history track presentation and bilingual copy behavior.

## [3.4.35] - 2026-07-10

### Added

- Added App Store event deep linking into Realtime translation.

## [3.4.34] - 2026-07-10

### Improved

- Split sidebar history into text and realtime sections with incremental loading.
- Preserved realtime history transcription model metadata during audio post-processing.

### Fixed

- Kept realtime history microphone translation moving after transient segment translation failures.

## [3.4.33] - 2026-07-09

### Improved

- Refined realtime history caption switching, microphone processing progress, and audio/LRC export.

## [3.4.32] - 2026-07-06

### Added

- Saved Markdown annotations on history records and realtime transcript cells.

### Improved

- Sent macOS chat messages with Shift+Return.

## [3.4.31] - 2026-07-04

### Improved

- Refined realtime caption alignment and history audio reprocessing.
- Refreshed localized translation workflow copy.

## [3.4.30] - 2026-07-03

### Added

- Added support for local realtime recognition models.
- Persisted audio with realtime history sessions.

### Improved

- Matched realtime toolbar and sidebar backgrounds with the surrounding app chrome.
- Updated internal agent workflow and lint guidance.

### Fixed

- Reset history detail view identity when switching sessions.

## [3.4.29] - 2026-07-02

### Improved

- Rendered rich Markdown, diff, and follow-up result content more clearly.
- Refined macOS navigation and conversation inspector presentation.

### Fixed

- Prevented repeated realtime caption start requests while startup is still loading.

## [3.4.28] - 2026-06-26

### Fixed

- Kept premium model access stable in translation extensions.
- Kept TestFlight premium overrides available inside app extensions.
- Prevented stale Direct refresh-token replays from signing out active devices.

## [3.4.27] - 2026-06-25

### Added

- Added realtime history sessions with structured transcript details.

### Improved

- Refined premium model selection and visibility.
- Improved realtime caption presentation and model selection polish.

### Fixed

- Kept speech analyzer startup asynchronous.
- Reduced false unexpected speech end reports during realtime sessions.
- Hardened realtime captions and localization.

## [3.4.26] - 2026-06-21

### Improved

- Refined realtime Mac audio setup guidance and notch caption display.
- Improved entitlement status labels for debug and TestFlight premium access.

## [3.4.25] - 2026-06-20

### Improved

- Refreshed app localizations across realtime, paywall, settings, provider, and service messages.

## [3.4.24] - 2026-06-19

### Added

- Added diagnostic log export and a faster onboarding feedback shortcut.

### Improved

- Refined Mac settings organization and realtime caption controls.
- Feedback diagnostics now produce cleaner logs with quieter successful network entries.
- Documented the Direct auth and release install flow.

### Fixed

- Hardened OAuth refresh handling.
- Polished the macOS selection popup footer layout.

## [3.4.23] - 2026-06-16

### Added

- Added scroll controls for realtime notch captions.

### Improved

- Refined realtime notch captions for compact inactive states and built-in MacBook notch displays.
- Realtime capture and recognition interruptions now surface actionable recovery messages.

## [3.4.22] - 2026-06-15

### Added

- Added realtime caption notch mode.

### Fixed

- Kept the macOS translation window width stable across updates.
- Kept the composer centered while typing.
- Refined realtime transcript revision matching for Chinese recognition updates.

## [3.4.21] - 2026-06-13

### Improved

- Refined purchase management, feedback collection, and translation input ergonomics.
- Retired the legacy Azure gateway path in favor of the current cloud proxy.

### Fixed

- Hardened OAuth refresh handling against replayed refresh requests.

## [3.4.20] - 2026-06-12

### Improved

- Premium model trial choices now stay visible in conversation flows and prompt non-Pro users to upgrade when needed.
- Default translator onboarding copy and layout now better match the real setup and trial flow.
- Refreshed App Store metadata for the current release.

## [3.4.19] - 2026-06-12

### Added

- Onboarding now includes a premium model trial sheet and trial bypass support in the LLM proxy.

### Improved

- Default translation onboarding now reuses the extension UI, supports expanded trial model coverage, and has clearer localized model loading copy.

### Fixed

- Onboarding paywall dismissal now closes cleanly.

## [3.4.18] - 2026-06-10

### Improved

- Onboarding now wakes up correctly when starting a default-translation premium trial.

## [3.4.17] - 2026-06-08

### Improved

- Onboarding now plays the success celebration and rating prompt after starting a premium trial, matching the standard "Start translating" flow.

## [3.4.16] - 2026-06-08

### Fixed

- Direct release workflow now builds on the `macos-26` runner so the macOS 26 SDK deployment target resolves correctly.
- Direct release signing now adds the temporary keychain to the search list so `xcodebuild` can locate the Developer ID Application identity during archive.

## [3.4.15] - 2026-06-08

### Changed

- Direct release workflow now runs on GitHub-hosted macOS runners and retries notarization on transient network failures.

## [3.4.14] - 2026-06-08

### Added

- New default translation onboarding flow guides first-time setup.
- Onboarding now offers a premium model trial, with free trial duration shown on the paywall.

### Improved

- Reworked the onboarding premium upsell for a clearer experience.
- Refined the iPad and composer UI.

## [3.4.13] - 2026-06-04

### Added

- Premium gating now protects paid translation features across app workflows.
- Direct builds now expose update controls from the app toolbar.

### Improved

- Apple Translate timeout handling is more resilient.
- Built-in action prompts are clearer and more consistent.

## [3.4.12] - 2026-06-04

### Improved

- Realtime captions update more smoothly and show language direction more clearly in multi-model snapshots.
- Home controls are easier to reach, with model selection kept near the input and selected action chips kept in view.
- Refreshed the App Store presentation with updated naming and subtitle metadata.

### Fixed

- Stabilized realtime captions during longer sessions.

## [3.4.11] - 2026-06-03

### Improved

- Spotlighted Realtime translation: speak and watch live bilingual captions appear as you talk.
- Refreshed the App Store presentation with new screenshots and release notes.

## [3.4.10] - 2026-06-03

### Improved

- iOS onboarding now introduces Premium more clearly for new users.
- iPhone tab action opens the primary translation workflow more directly.
- Expanded language picker coverage with more regional language options.

## [3.4.9] - 2026-06-03

### Added

- Search field in the language picker to quickly find a language.

### Improved

- Unified the language selection and swap controls across text and realtime translation.
- Realtime captions can optionally show the original untranslated text alongside the translation.
- Smoother realtime caption rendering and incremental updates.

## [3.4.8] - 2026-06-02

### Added

- Automatic source language detection for more accurate translations.
- Tap a translation result on iPhone to open a detailed view.

### Improved

- macOS: Actions and Models now open from Home and Settings instead of the sidebar, with the model picker in the Home toolbar.
- Refined the language switcher and selector UI.
- Realtime now remembers caption visibility and has smoother incremental translation.
- Polished the satisfaction prompt.

## [3.4.7] - 2026-06-01

### Added

- Translation prompts now include the source language for more accurate results.
- The prompt editor highlights `{text}`, `{sourceLanguage}`, and `{targetLanguage}` placeholders.

### Improved

- Simplified the iOS model selection UI.
- Refined the realtime language picker behavior.
- Reorganized the built-in custom actions.

### Fixed

- Hardened realtime speech startup.

## [3.4.6] - 2026-05-30

### Added

- iOS realtime microphone support.

### Improved

- Refreshed the app UI with updated Liquid Glass styling.
- Removed the realtime caption text outline.

### Fixed

- Realtime start blockers now show actionable explanations.
- Apple Translate realtime startup now checks installed language packs before starting.

## [3.4.5] - 2026-05-28

### Added

- Floating caption controls can close and clear the current realtime caption session.

### Improved

- Pending realtime translations are preserved in history before finalization.

## [3.4.4] - 2026-05-28

### Added

- Azure GPT Realtime translation provider with streaming translation-only output and synthesized voice playback.

## [3.4.3] - 2026-05-27

### Improved

- Unified realtime caption visibility between the menu bar toggle and the in-view toggle so hiding captions no longer pauses recognition.

### Fixed

- Preserved cached translations for multi-sentence committed segments instead of clearing them on the next update.

## [3.4.2] - 2026-05-27

### Added

- Azure Whisper realtime captioning.

## [3.4.1] - 2026-05-27

### Added

- Floating realtime caption control for starting, pausing, and resuming recognition.

## [3.4.0] - 2026-05-27

### Added

- Realtime translation tab.
- Admin usage dashboard.
- DeepSeek V4 Flash provider option.

### Changed

- Prefer Chrome plugin for browser automation guidance.

## [3.3.5] - 2026-05-24

### Changed

- Bumped the app marketing version to 3.3.5 and documented the release tag/version match requirement.

## [3.3.3] - 2026-05-17

### Changed

- Release pipeline now runs on a self-hosted macOS runner (replaces GitHub-hosted `macos-26`) to avoid CI minute exhaustion. Xcode is selected via `DEVELOPER_DIR` instead of `sudo xcode-select`, so the same workflow works on either runner type.

## [3.3.2] - 2026-05-17

### Fixed

- Direct build failed to compile (`v3.3.1` CI was red) because `.pricing` no longer refers to an enum case after the `email` parameter was added. Call sites now pass `.pricing(email: nil)` explicitly; Swift enum cases cannot have parameter defaults.

## [3.3.1] - 2026-05-17

### Added

- Stripe-as-source-of-truth entitlement sync: hourly cron reconciles Supabase against Stripe, plus `/api/admin/active-users` and `/api/admin/sync-entitlements` admin endpoints. Entitlements are identified by `price.id`, so coupons / 100%-off promos resolve correctly.
- Subscribe-on-Web now carries the signed-in email through to Stripe Checkout so returning users skip the email-entry step.
- "Contact support" action on the paywall when signed in but no Stripe entitlement is found; the email is pre-populated with diagnostics.

### Changed

- Sidebar footer always shows the signed-in email (previously only when Pro), so users can tell which account "Restore" is checking.
- "Refresh subscription status" now always forces a network round-trip; previously the stale-token short circuit silently no-op'd when the access token hadn't expired.
- Paywall copy for the signed-in-but-not-Pro state explains the three likely causes (haven't subscribed, wrong email, not synced yet) instead of a single generic line.

### Fixed

- Lifetime purchase reconciliation no longer downgrades active lifetime rows to `status: "complete"`, which `getBillingStatus` would have read as not-Pro.
- Subscription reconciliation reads `current_period_end` from `subscription.items.data[0]` for the 2026-04 Stripe API where the field moved off the subscription root.
- Refund detection in the reconciliation path now mirrors `buildChargeRefundRevocation`: only full refunds revoke access; partial refunds keep the entitlement.

## [3.3.0] - 2026-05-17

### Added

- Web contact entry points and paywall polish.

## [3.2.9] - 2026-05-17

### Added

- Developer-mode runtime gate for the in-app network inspector.
- Resizable menu bar popover via a bottom drag handle (macOS).

### Changed

- Menu bar popover handoff, RTL text rendering, and width resize behavior.
- Resizable selection translation popup; added OAuth activation diagnostics.
- Friendlier Apple Translate extension prompt with edge-case debug output.
- Restructured Sentence Analysis prompt for clearer results.

### Removed

- GitHub Actions CI workflow to reduce Actions minutes usage.

## [3.2.8] - 2026-05-12

### Added

- Direct (macOS): the sidebar Premium row now shows the subscriber email
  in secondary text underneath the "Active" indicator, so users can see
  at a glance which account the current entitlement belongs to.

### Fixed

- Direct (macOS): when the OAuth activation callback arrives without a
  matching in-app PKCE flow (e.g. the user completed `/activate` purely
  on the website), the app now automatically presents the paywall so
  activation can be re-started in-app instead of silently failing.
  Cold-launch callbacks are also handled via a sticky flag so the prompt
  is not lost when the window has not yet mounted.

## [3.2.7] - 2026-05-12

### Fixed

- Direct (macOS): completing the web subscription flow no longer spawns a
  second TLingo window. The `tlingo-direct://oauth/callback` deeplink is
  now declared in `handlesExternalEvents`, so the existing window receives
  the callback instead of SwiftUI opening a fresh WindowGroup instance.

### Changed

- Direct (macOS): suppressed the Data Sharing Notice on first translation.
  Direct users explicitly chose a self-hosted/Developer-ID build, so the
  cloud-proxy consent prompt is not shown.

## [3.2.6] - 2026-05-12

### Changed

- Stripe subscription / refund / cancellation status now propagates to the
  Direct Mac app within at most 6 hours (or the next time the app comes to
  the foreground), instead of only at next launch. Concurrent refresh
  attempts coalesce so foreground transitions and the periodic ticker
  never issue duplicate `/oauth/token` round-trips.

### Fixed

- Post-checkout one-click activation now accepts trial entitlements stored
  with the legacy `on_trial` status (previously rejected with
  `no_active_entitlement`, forcing users into the OTP fallback).
- Refresh ticker no longer triggers unnecessary SwiftUI invalidations or
  `AppPreferences` disk writes when the entitlement is unchanged.

## [3.2.5] - 2026-05-12

### Changed

- Billing migrated from Dodo Payments back to Stripe (Checkout + Billing
  Portal). Email-first flow: anonymous buyers are resolved to a Supabase
  user via webhook find-or-create, returning subscribers reuse their
  existing Stripe customer.

### Added

- Zero-input post-checkout activation for the Direct build.

### Removed

- Legacy Supabase magic-link auth path.

## [3.2.4] - 2026-05-12

### Security

- Disabled the TestFlight double-tap "premium" backdoor in the Direct
  build. The version-label gesture is no longer registered there at all,
  and `StoreManager.toggleTestFlightPremium()` short-circuits with a log
  warning if invoked. The Direct channel's premium state is owned
  exclusively by the web entitlement (Supabase + Dodo).

### Fixed

- Direct build incorrectly fell through to the App Store StoreKit code path
  when Supabase secrets were not yet wired up in CI, leaving the legacy
  `is_premium_subscriber=true` from a prior App Store install in place. The
  Direct channel is now identified by an explicit `TLingoDistributionChannel`
  Info.plist marker injected via `Direct.xcconfig`, independent of any
  optional secrets.

### Added

- **Selection Translation** is now available in the Direct build. Enable it in
  Settings → "Text Selection Translation" and grant macOS Accessibility access
  when prompted. App Store sandbox forbids this capability so it remains
  Direct-only.

### Fixed

- Pro / premium status no longer leaks from a previous App Store install when
  switching to the Direct build at the same Bundle ID. The Direct build now
  ignores the legacy `is_premium_subscriber` UserDefaults key, purges any
  leftover values on first launch, and bridges the live web entitlement
  through `StoreManager` so existing UI (Settings accent picker, Models view,
  feedback subject) reflects the real Pro/Free state.

## [3.2.0] - 2026-05-10

### Added

- **TLingo Direct** — new macOS distribution channel signed with our Apple Developer ID
  and notarized by Apple. Available at <https://tlingo.zanderwang.com/download>.
- Sparkle 2 auto-update for the Direct build (EdDSA-signed appcast hosted on Cloudflare R2).
- Email OTP sign-in via Supabase, replacing StoreKit subscriptions for the Direct channel.
- Worker `/billing/{status,checkout,portal,webhook}` endpoints powering the web checkout
  flow (DodoPayments).
- "Check for Updates…" and "Sign In…" menu items in the macOS app menu (Direct only).
