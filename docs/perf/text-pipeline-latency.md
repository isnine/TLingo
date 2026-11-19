---
status: current
owner: ios
verified_commit: e6749b0ba0c80b9e59f1ea0f2d22dc82709fa7c1
review_triggers:
  - DebugLaunchTestHarness changes
  - TranslationTimingTrace stage changes
  - ActionConfig structuredOutput or OutputType changes
  - LLMService request preparation changes
---

# Text Pipeline Latency Testing & Benchmarks

End-to-end latency profiling methods, telemetry definitions, and measured baselines across the text pipeline:

`Client Prepare -> Network / Edge Transit -> Upstream Provider -> SSE Stream -> Diff / Markdown / UI Frame`

## Test Systems (`#if DEBUG` Only)

### 1. Launch-Argument Multi-Action Harness (`DebugLaunchTestHarness`)

Implemented in `ios/ShareCore/UI/Home/DebugLaunchTestHarness.swift` and wired into `AITranslatorApp` and `HomeView`. Launches directly into `HomeView`, skips onboarding/whats-new sheets, selects actions and models, expands the multi-model results panel, triggers the production `HomeViewModel` pipeline, and waits for async diff and `CADisplayLink` frame completion (`TranslationFrameProbe`). User preferences are restored after multi-action serial suites.

Supported arguments (or `TLINGO_DEBUG_*` environment variables, where `SIMCTL_CHILD_` is forwarded by `simctl`):

| Launch Argument | Env Variable | Values & Default |
| --- | --- | --- |
| `-TLingoDebugActions` | `TLINGO_DEBUG_ACTIONS` | Comma-separated action IDs (`translate`, `polish`, `grammar-check`, `simplify`, `sentence-analysis`, `sentence-translate`) or `all` |
| `-TLingoDebugAction` | `TLINGO_DEBUG_ACTION` | Single action ID alias |
| `-TLingoDebugModels` | `TLINGO_DEBUG_MODELS` | `all` (default), `cloud`, or comma-separated model IDs (`gpt-5-mini,deepseek-flash,...`) |
| `-TLingoDebugExecutionMode` | `TLINGO_DEBUG_EXECUTION_MODE` | `parallel` or `serial` (defaults to `parallel` for 1 action, `serial` for multiple) |
| `-TLingoDebugInputPreset` | `TLINGO_DEBUG_INPUT_PRESET` | `short` (default), `long`, or `both` |
| `-TLingoDebugText` | `TLINGO_DEBUG_TEXT` | Explicit input text override |
| `-TLingoDebugSourceLanguage` | `TLINGO_DEBUG_SOURCE_LANGUAGE` | Source language code (default `en`) |
| `-TLingoDebugTargetLanguage` | `TLINGO_DEBUG_TARGET_LANGUAGE` | Target language code (default `zh-Hans`) |
| `-TLingoDebugRepeats` | `TLINGO_DEBUG_REPEATS` | `1...20` (default `1`) |
| `-TLingoDebugOutput` | `TLINGO_DEBUG_OUTPUT` | Output directory path (defaults to `<Documents>/debug-pipeline-benchmark`) |

Outputs written to the output directory:

- `models.json`: resolved `ModelConfig` catalog entries
- `results.json`: per-run `TranslationTimingTrace.Snapshot`, `URLSessionTaskTransactionMetrics`, `Server-Timing`, `CF-Ray`, and `SegmentBreakdown`
- `summary.json`: aggregated min/median/avg/max statistics grouped by `(actionID, inputPreset, modelID)`
- `complete.txt` (or `error.txt` on failure)

Per-run `[DebugTiming]` summaries are also logged to OSLog (`subsystem == "com.zanderwang.AITranslator" AND category == "DebugTiming"`).

#### Running on iOS Simulator

```bash
CONTAINER=$(xcrun simctl get_app_container <UDID> com.zanderwang.AITranslator data)
xcrun simctl launch --terminate-running-process <UDID> com.zanderwang.AITranslator \
  -TLingoDebugActions translate,polish,grammar-check \
  -TLingoDebugModels gpt-5-mini,deepseek-flash,gemini-3.8-flash,gpt-5.6,microsoft-translate \
  -TLingoDebugExecutionMode parallel \
  -TLingoDebugOutput "$CONTAINER/Documents/debug-after-opt"
```

#### Running on Physical iPhone (`devicectl`)

Omit `-TLingoDebugOutput` on physical devices so the app writes inside its sandboxed `Documents/debug-pipeline-benchmark` directory. Pass `--` before flags starting with `-` so `devicectl` forwards them to the app instead of parsing them as CLI options.

```bash
xcodebuild -project ios/AITranslator.xcodeproj -scheme TLingo -configuration Debug \
  -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates build

BUILT_DIR=$(xcodebuild -project ios/AITranslator.xcodeproj -scheme TLingo -configuration Debug \
  -destination 'platform=iOS,id=<UDID>' -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/BUILT_PRODUCTS_DIR/{print $2; exit}')

xcrun devicectl device install app --device <UDID> "$BUILT_DIR/TLingo.app"

xcrun devicectl device process launch --device <UDID> --terminate-existing com.zanderwang.AITranslator -- \
  -TLingoDebugActions translate,polish,grammar-check \
  -TLingoDebugModels gpt-5-mini,deepseek-flash,gemini-3.8-flash,gpt-5.6,microsoft-translate \
  -TLingoDebugExecutionMode parallel

# Copy individual result files from the app sandbox
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.zanderwang.AITranslator \
  --source Documents/debug-pipeline-benchmark/results.json --destination /tmp/device-results.json
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.zanderwang.AITranslator \
  --source Documents/debug-pipeline-benchmark/summary.json --destination /tmp/device-summary.json
```

### 2. Legacy Env-Var Text Translation Benchmark (`TextTranslationBenchmarkView`)

Dedicated serial `translate`-only benchmark triggered via `SIMCTL_CHILD_TLINGO_TEXT_BENCHMARK=1`; see [`../verification.md`](../verification.md) for usage. Uses the same `TranslationTimingTrace` and `TranslationFrameProbe` instrumentation.

### 3. Live Network Inspector & Instruments Signposts

- **OSSignposter**: `PerformanceSignposts.signposter` emits `Translation Run` intervals (`submitted -> resultApplied`) and `Translation Stage` events (`subsystem == "com.zanderwang.AITranslator"`).
- **Network Inspector (`DebugNetworkProtocol`)**: Captures `URLSessionTaskTransactionMetrics` (`domainLookup`, `connect`, `secureConnection`, `request`, `response`, `isReusedConnection`, `networkProtocolName`) correlated by `X-Request-ID`.

---

## Full-Pipeline Timing Stages (`TranslationTimingTrace`)

Monotonic timestamps recorded in `ios/ShareCore/Networking/TranslationTimingTrace.swift` relative to user submission (`startedAt`):

1. `languageResolved` -> **`languageResolutionMs`**: Language detection and auto-target resolution (`consumeResolvedTarget`).
2. `requestPrepared` -> **`requestPreparationMs`**: Main-thread UI submission through request body/header serialization before `URLSession` starts.
3. `responseHeaders`: First HTTP response headers received:
   - **`upstreamHeaderTTFBMs`** (`Server-Timing: upstream;dur=...` / `X-Upstream-TTFB`)
   - **`workerPreUpstreamMs`** (`Server-Timing: preupstream;dur=...`)
   - **`clientToWorkerTransitResidualMs`** (`responseHeaders - requestPrepared - workerPreUpstreamMs - upstreamHeaderTTFBMs`)
4. `firstContent` -> **`headersToFirstContentMs`**: Delay from HTTP headers to first non-empty SSE delta.
5. `firstUsefulContent` -> **`jsonPrefixToFirstUsefulContentMs`**: JSON scaffolding prefix wait before the first visible character (or `0` for plain-text streams).
6. `firstUIUpdate` / `firstUIFrame` (`CADisplayLink` +2 ticks) -> **`firstUIUpdateToFirstFrameMs`** & **`timeToFirstVisibleTextMs`**.
7. `lastContent` -> **`streamingGenerationMs`** (`lastContent - firstUsefulContent`).
8. `streamFinished` -> **`streamTailToFinishMs`** (`streamFinished - lastContent`).
9. `resultApplied` -> **`finalParseAndApplyMs`** (`resultApplied - streamFinished`).
10. `diffComputed` -> **`diffComputeMs`** (parallel `TextDiffBuilder.build` latency from `resultApplied`).
11. `markdownParsed` -> **`markdownParseMs`** (`MarkdownContentView` parse completion from `resultApplied`).
12. `finalUIFrame` (`CADisplayLink` +2 ticks after `.success` / `.diffComputed`) -> **`resultApplyToFinalFrameMs`** & **`totalEndToEndMs`**.

---

## Measured Pipeline Latency & Optimizations

### Baseline Findings (Before Optimization)

Measured on iOS Simulator (iPhone 17e, iOS 27.2) across 2 parallel multi-model runs and a 74-run serial multi-action suite:

1. **Main-actor contention during pre-request setup (`requestPreparationMs`: `667–1,812 ms` parallel)**:
   `HomeViewModel` assigned `modelRuns` (triggering SwiftUI to mount 7–8 Shimmer result cards), and then each parallel child task inside `LLMService.sendModelRequest` hopped back to `MainActor.run` inside `UsageSubjectProvider.current()` (plus Keychain `SecItemCopyMatching` on first call). All 7–8 HTTP requests stalled waiting for `@MainActor` layout completion.
2. **Unordered `jsonSchema` property serialization in `grammar-check` (`jsonPrefixToFirstUsefulContentMs`: `3,840.9 ms` on `gpt-5.6`)**:
   `ActionConfig.StructuredOutputConfig.responseFormatPayload()` converted `jsonSchema` into `[String: Any]` and re-serialized with `JSONSerialization`, reordering properties alphabetically so `additional_text` preceded `revised_text`. `gpt-5.6` streamed ~200 chunks (3.84 s) of grammar commentary before emitting the first character of `revised_text`.
3. **Redundant `text_response` JSON Schema wrapper on `.translate` and `.diff` (`110–358 ms` extra TTFB)**:
   Wrapping single-field plain text outputs in `{"text": "..."}` forced models (`gpt-5-mini`, `deepseek-flash`) to emit JSON scaffolding tokens before showing the first visible character.
4. **End-of-stream Markdown re-parse & un-debounced history queries (`resultApplyToFinalFrameMs`: `213–939 ms` parallel)**:
   Switching from `StreamedMarkdownView` to `MarkdownContentView` forced an asynchronous `MarkdownParserImpl().parse(...)` even for plain text without Markdown syntax, while 7 concurrent completions each posted `.translationRecordSaved`, triggering 7 un-debounced SwiftData scans (up to 500 records each) inside `HomeView.refreshRecentTextRecords()`.
5. **Cloud edge & gateway transit overhead (`clientToWorkerTransitResidualMs`: `245–385 ms`)**:
   Even with reused HTTP/2 or HTTP/3 connections (`workerPreUpstreamMs = 0–4 ms`), client requests routed through a regionally placed Worker and upstream AI Gateway add ~250–385 ms fixed round-trip residual.

### Implemented Optimizations

1. **Zero-`@MainActor`-hop request preparation**: Added `UsageSubjectProvider.currentMainActor()`, resolved `UsageSubject` and `isPremium` once before launching `withTaskGroup`, and passed them into `LLMService.sendModelRequest` (`requestPreparationMs` reduced to `115 ms` on cold batch 1 and `34–42 ms` on warm batches on iPhone 15 Plus).
2. **Deterministic JSON Schema property order**: Added `StructuredOutputConfig.validatedRawJSONSchema`, spliced `rawSchema` directly into `LLMRequestPayload` JSON bytes in `LLMService.swift`, and explicitly instructed `revised_text` first in `BuiltInActionCatalog.swift` (`grammar-check` prefix wait on `gpt-5.6` cut from `3,840.9 ms` to `6.8 ms` on iPhone 15 Plus / `144.4 ms` on simulator).
3. **Plain-text streaming for single-field `.translate` and `.diff`**: Returned `nil` from `OutputType.structuredOutput` for `.translate` and `.diff` (`jsonPrefixToFirstUsefulContentMs` dropped from `110–358 ms` to `< 0.1 ms`).
4. **Markdown plain-text fast path + cache & 250 ms history debounce**: Added `MarkdownContentView.containsMarkdownSyntax(_:)` bypass and a 64-entry `@MainActor` `RenderableDocument` cache, plus a 250 ms `Task` debounce on `.translationRecordSaved` in `HomeView+InputAndChrome.swift`.

### Before vs. After Benchmark Comparison (Parallel Multi-Model Runs)

All post-optimization runs executed in parallel mode (5 models for `translate`, 4 models for `polish` and `grammar-check`; 13/13 succeeded on both simulator and physical iPhone 15 Plus):

| Stage Metric | Baseline Simulator (Parallel / Serial) | Post-Opt Simulator (iPhone 17e) | Post-Opt Physical Device (iPhone 15 Plus, `h3`) |
| --- | --- | --- | --- |
| `requestPreparationMs` (batch 1 cold parallel) | `1,812 ms` (`translate`, 8 models) | **`451.4 ms`** | **`115.6 ms`** (-93.6%) |
| `requestPreparationMs` (batch 2+ warm parallel) | `667 ms` (`polish`, 7 models) | **`154.1–230.8 ms`** | **`34.2–42.2 ms`** (-93.7%) |
| `jsonPrefixToFirstUsefulContentMs` (`translate`/`polish` `gpt-5-mini`) | `195–297 ms` (serial) | **`0.016–0.021 ms`** | **`0.052–0.083 ms`** (~0 ms) |
| `jsonPrefixToFirstUsefulContentMs` (`translate`/`polish` `deepseek-flash`) | `110–150 ms` | **`0.024–0.038 ms`** | **`0.008–0.020 ms`** (~0 ms) |
| `jsonPrefixToFirstUsefulContentMs` (`grammar-check` `gpt-5.6`) | `3,840.9 ms` (serial) | **`144.4 ms`** | **`6.8 ms`** (-99.8%) |
| `markdownParseMs` (`translate` / `polish` plain text) | `73–563 ms` (parallel) | **`11.7–33.6 ms`** | **`7.2–29.6 ms`** |
| `firstUIUpdateToFirstFrameMs` | `213–888 ms` (parallel) | `33–614 ms` (sim) | **`22.2–70.6 ms`** |
| `resultApplyToFinalFrameMs` | `93–939 ms` (parallel) | `37–474 ms` (no diff contention) | **`18.2–158.5 ms`** |

#### iPhone 15 Plus End-to-End Snapshot (`h3`, Parallel Mode)

| Action | Model | Upstream TTFB | Client Prep | Transit Residual | First Visible Text | Total E2E |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `translate` | `microsoft-translate` | 143 ms | 114.9 ms | 425.2 ms | **804.2 ms** | **804.3 ms** |
| `translate` | `gpt-5-mini` | 738 ms | 115.6 ms | 428.2 ms | **1,436.8 ms** | **1,693.8 ms** |
| `translate` | `deepseek-flash` | 474 ms | 115.8 ms | 939.1 ms | **1,553.9 ms** | **1,703.2 ms** |
| `translate` | `gemini-3.8-flash` | 1,369 ms | 115.6 ms | 363.4 ms | **1,870.6 ms** | **2,190.0 ms** |
| `translate` | `gpt-5.6` | 2,414 ms | 115.7 ms | 388.8 ms | **2,969.7 ms** | **3,451.1 ms** |
| `polish` | `gpt-5-mini` | 362 ms | 42.2 ms | 384.8 ms | **841.1 ms** | **1,636.1 ms** |
| `polish` | `deepseek-flash` | 388 ms | 42.2 ms | 357.7 ms | **1,636.0 ms** | **1,684.3 ms** |
| `polish` | `gpt-5.6` | 1,944 ms | 42.2 ms | 316.7 ms | **2,355.2 ms** | **2,882.6 ms** |
| `polish` | `gemini-3.8-flash` | 3,006 ms | 42.2 ms | 355.1 ms | **3,475.1 ms** | **3,515.0 ms** |
| `grammar-check` | `gpt-5-mini` | 654 ms | 34.2 ms | 318.2 ms | **1,063.3 ms** | **3,199.7 ms** |
| `grammar-check` | `deepseek-flash` | 456 ms | 34.4 ms | 766.0 ms | **1,380.1 ms** | **2,563.6 ms** |
| `grammar-check` | `gemini-3.8-flash` | 1,800 ms | 34.4 ms | 327.4 ms | **2,316.7 ms** | **4,606.9 ms** |
| `grammar-check` | `gpt-5.6` | 2,008 ms | 34.2 ms | 606.2 ms | **2,678.3 ms** | **6,525.1 ms** |

## Invariants Going Forward

- **Never reintroduce per-model `@MainActor` hops or Keychain reads** inside `LLMService.sendModelRequest`; always resolve `UsageSubject` and `isPremium` once before launching concurrent model tasks.
- **Never round-trip `StructuredOutputConfig.jsonSchema` through `[String: Any]`**: multi-field streaming depends on `primaryField` staying first in the JSON Schema sent to providers.
- **Keep single-field actions (`translate`, `diff`, `markdown`) out of JSON Schema wrappers** unless multiple distinct fields must be parsed from the same response.
- **Keep `.translationRecordSaved` UI listeners debounced** (`250–500 ms`) so concurrent multi-model completions do not trigger back-to-back SwiftData scans on the main thread.
