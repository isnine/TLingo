---
status: current
owner: ios
verified_commit: e6749b0ba0c80b9e59f1ea0f2d22dc82709fa7c1
review_triggers:
  - DebugLaunchTestHarness changes
  - DebugStreamingRenderView changes
  - DebugDevicePerformanceView workload changes
  - TranslationTimingTrace stage changes
  - ActionConfig structuredOutput or OutputType changes
  - LLMService request preparation changes
---

# Text Pipeline Latency Testing & Benchmarks

End-to-end latency profiling methods, telemetry definitions, and measured baselines across the text pipeline:

`Client Prepare -> Network / Edge Transit -> Upstream Provider -> SSE Stream -> Diff / Markdown / UI Frame`

## Test Systems (Debug Unless Noted)

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

### 3. Offline Streaming Render Stress (`DebugStreamingRenderView`, iOS)

Launch with `-TLingoDebugRenderStreams 30` to replay synchronized model output through the production update coalescers and result panel, without model discovery, HTTP/SSE decoding, provider calls, or History writes. The stream count defaults to 30 and accepts 1–30. Add `-TLingoDebugRenderExpanded` to expand all results before the first batch. Use `-TLingoDebugRenderFixture text|markdown|pairs` (default: `text`) to select the output.

```bash
xcrun devicectl device process launch --device <UDID> --terminate-existing com.zanderwang.AITranslator -- \
  -TLingoDebugRenderStreams 30 -TLingoDebugRenderExpanded -TLingoDebugRenderFixture text
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.zanderwang.AITranslator \
  --source Documents/debug-streaming-render.json --destination /tmp/tlingo-render.json
```

The scenario starts automatically and can be repeated in place with **Replay**. Each run delivers 180 synchronized batches at 20 ms intervals, then completes all runs together. Keep the app in the foreground and copy the report after the app shows the result. The report includes sample count, P95/P99/max display-link intervals, and estimated missed 60 Hz callbacks for the first 250 ms, the remaining stream, and the completion window.

- `-TLingoDebugRenderInteraction scroll`: animate the production results scroll view between offsets 0 and 1,400 points. Start expanded for a comparable scroll range.
- `-TLingoDebugRenderInteraction toggle`: alternate expanding and collapsing the production comparison panel. Omit the option for a stationary control.
- The final action is scheduled just before completion so its animation can overlap the result commits. Verify `interaction.actionTimesMs` and `interaction.maxOffsetPoints`/`scrollDistancePoints` in the report rather than assuming the scheduled action happened on time. Use `-TLingoDebugRenderLabel <label>` to distinguish runs when polling the same report path.

These are frame-pacing proxies, not GPU-present counts or touch latency. Compare the same fixture, panel state, build configuration, device, and refresh rate across fresh launches. A local development-signed Release build can explicitly include only the render harness:

```bash
xcodebuild -project ios/AITranslator.xcodeproj -scheme TLingo -configuration Release \
  -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) TLINGO_LOCAL_RENDER_BENCHMARK' build
```

Default Release builds do not define `TLINGO_LOCAL_RENDER_BENCHMARK`.

#### iPhone 15 Plus Debug A/B

Runs started in fresh processes. The baseline uses the same offline harness and the previous eager comparison stack. The optimized iOS comparison stack loads rows lazily and skips a redundant pending partial when committing the final result.

| Fixture | Layout | Streaming P95 before → after | Estimated missed callbacks during streaming |
| --- | --- | --- | --- |
| 30 plain-text streams | Expanded | 806–824 ms → 16.6 ms | 146–149 → 0 |
| 30 plain-text streams | Collapsed | 16.6 ms → 16.6 ms | 0 → 0 |
| 30 Markdown streams | Expanded | 834 ms → 16.6 ms | 145 → 0 |
| 30 sentence-pair streams | Expanded | 426 ms → 16.6–30.5 ms | 151 → 0–17 |

The expanded plain-text baseline had only 5–6 streaming callbacks in its sample window; the optimized runs had 200. Plain-text expansion still had a 65–75 ms maximum interval in the first 250 ms. Sentence-pair completion peaked at 65–130 ms in two runs. These are stationary Debug measurements, not Release or scroll benchmarks.

### 4. Local Device Workloads (`DebugDevicePerformanceView`, iOS)

These workloads are available in Debug and in a local development-signed Release build with `TLINGO_LOCAL_DEVICE_BENCHMARK` added to `SWIFT_ACTIVE_COMPILATION_CONDITIONS` using the command above. The default Release build does not include them.

Use the following launch arguments after `devicectl device process launch --device <UDID> --terminate-existing com.zanderwang.AITranslator --`:

| Arguments | Path measured |
| --- | --- |
| `-TLingoDebugDevicePerf history -TLingoDebugHistoryCount 10000` | Save synthetic text records to a temporary SwiftData store, reopen it in-process, and fetch and decode 50-record pages at multiple offsets. Never uses the shared history store. |
| `-TLingoDebugDevicePerf history-audio -TLingoDebugWaveformBuckets 1200` | Build a one-hour-class timeline from the WAV fixture and generate waveform buckets using the production audio pipeline. The default is 256 buckets; 1,200 matches the player. Uses a uniquely named temporary recording directory and does not play audio or measure scrubbing. |
| `-TLingoDebugDevicePerf ocr` | Run the production OCR recognizer five times on the same generated 3024 × 4032 image (56 lines of mixed English and Chinese). Times exclude image generation, photo import, and editor presentation. |
| `-TLingoDebugDevicePerf realtime -TLingoDebugAudioSeconds 300` | Feed a local speech fixture into the production FluidAudio recognizer at 1× wall-clock speed. Records engine loading, time to the first nonempty recognition callback, audio backlog, sampled physical footprint and thermal state, and finalization. |
| `-TLingoDebugDevicePerf realtime-lifecycle -TLingoDebugAudioSeconds 18` | Run the same replay twice in one process, then explicitly purge the idle engine. Reports physical footprint before loading, after each stop, and two seconds after purge. Does not simulate backgrounding or an OS memory warning. |

For realtime and history audio, copy a nonempty mono 16 kHz WAV to `Documents/debug-realtime-fixture.wav` using `devicectl device copy to`. Use a 10–60 second fixture for history audio. Realtime replay loops the file until the requested audio duration (1–3,600 seconds; default 60). The default model is `nemotron-streaming-1120ms`; choose another available FluidAudio model with `-TLingoDebugRealtimeModel <id>`. Missing models fail unless `-TLingoDebugAllowModelDownload` is present, in which case `downloadMs` includes downloading and disk preparation, separately from engine loading. Existing models are not removed. Keep the foreground active; the file replay does not exercise capture, visible captions, PiP, or saving History.

Pass `-TLingoDebugPerfLabel <label>` and copy `Documents/debug-device-performance.json` after completion. Check the label, `error`, and `interrupted`. `debugLaunchToTaskMs` ends at the benchmark task, not at an interactive application home screen.

#### iPhone 15 Plus Device Baselines (iOS 27.2.1, 2026-11-19)

The offline render matrix used the opt-in local Release build, with two fresh launches per row and the panel initially expanded:

| Fixture | Interaction | Streaming P95 | Completion max |
| --- | --- | --- | --- |
| 8 plain-text streams | Stationary / scroll / toggle | 16.6 ms | 31–49 ms across all six runs |
| 30 sentence-pair streams | Stationary | 16.6 ms | 80–125 ms |
| 30 sentence-pair streams | Scroll | 16.6 ms | 82–127 ms |
| 30 sentence-pair streams | Toggle | 18.8–19.8 ms | 58–59 ms |

The scroll runs reached 1,400 points. In the 30-pair toggle runs, streaming P99 was 46.8–53.3 ms. An additional 30-pair scroll Instruments capture found nine hitches (worst: 116.51 ms) and no hang of 250 ms or longer. Main-thread samples around the worst hitch include SwiftUI layout and display-list work. Since completion spikes also occurred at rest, these runs point to profiling the final result commits and layout, not to scrolling as an established cause.

The local workloads below used the Debug build:

| Workload | Result |
| --- | --- |
| History, 5,000 and 10,000 synthetic records | Fetch 50 records: 0.69–7.26 ms; read and decode their payloads: 0.53–0.69 ms. Deepest offset had the slowest fetch. |
| History audio, 59 min 37 sec / 142 timeline segments | Build composition: 383 ms; compute 256 waveform buckets: 13.87 s. The fixture reuses a short WAV, so this is not a measurement of production file I/O or player responsiveness. |
| OCR, two processes with five passes each | First pass: 517 / 894 ms; later passes: 413–440 ms. All passes returned 3,472 characters. This bypasses the photo import path, including its initial downscale. |
| Cached Nemotron 1120 ms, 5 minutes at 1× | Engine load: 23.57 s; audio feed to first nonempty result: 1.56 s; maximum backlog: 0.55 s. All 300 seconds were processed. Sampled footprint peaked at 1,590 MiB after loading, then stayed near 1,525 MiB after 15 seconds. Sampled thermal state remained nominal. |
| Uncached Parakeet EOU 320 ms, one foreground run | Download and disk preparation: 122.00 s; engine load: 41.01 s; audio feed to first nonempty result: 1.03 s (about 164 s in total). |

These baselines do not cover History list/search/scrubbing, camera or photo import to an editable result, cold launch to interactive Home, online long-text latency, download resume, or extended microphone/ReplayKit capture with captions, PiP, lock screen, and battery drain.

#### Instruments Follow-up (Local Release, iPhone 15 Plus)

- **SwiftUI — 30 sentence-pair streams, expand/collapse:** the baseline captured six hitches, with a 116.54 ms worst hitch at 5.129 s. The 84.85 ms SwiftUI update transaction was triggered by publishing results from `HomeViewModel.apply(result:context:runToken:allowDiff:)`. This measures view updates after publication, not the cost of assigning the result.
- **Time Profiler — 59 min 37 sec history audio, 1,200 buckets:** composition took 321 ms and waveform generation took 311 ms, without a recorded hang. The waveform ran off the main thread; 65 of its 308 one-millisecond CPU samples landed in `AVAudioBuffer` teardown through `madvise`. The 13.87 s Debug result does not represent Release. The fixture still reuses one WAV across 142 segments, while production records separate five-second AAC segments; profile that format before prioritizing waveform optimization.
- **VM Tracker and Time Profiler — cached Nemotron 1120 ms, fresh process:** loading took 25.58 s even with the model on disk; the first nonempty recognition followed 1.52 s after replay began. The startup CPU window shows Core ML loading, execution-plan setup, and on-device compilation. The app sampled 1,580 MiB of physical footprint just after loading and about 1,523 MiB during the 35-second replay. The device remained nominal. This is a startup and memory-headroom risk, not evidence of a leak. The production engine cache intentionally keeps one idle engine, so measure repeated start/stop, model switching, and background eviction before changing its policy.

#### Sentence-Pair Completion Fix (Local Release, iPhone 15 Plus)

The streaming and final states now use the same sentence-pair view, and enabling result detail no longer replaces the row. Settled height measurements are stored without invalidating the panel; the held height still drives animation when switching result formats. Each model still publishes its completion as soon as it is ready.

| 30 sentence-pair streams | Baseline completion max (2 runs) | Fixed completion max (3 runs) |
| --- | --- | --- |
| Stationary | 80–125 ms | 31–33 ms |
| Scroll to 1,400 points | 82–127 ms | 32–39 ms |
| Expand/collapse | 58–59 ms | 16.6 ms |

With the same SwiftUI template, the result-publication transaction went from 84.85 to 10.30 ms; the largest hitch across the run went from 116.54 to 33.33 ms, with no hitch at completion in the fixed run. The separate Time Profiler + Hitches scroll capture went from nine hitches to four, and from 116.51 to 16.67 ms for the largest hitch. Neither fixed capture recorded a hang of at least 250 ms. App and ShareCore UUIDs matched the fixed build. Two 8-stream plain-text scroll controls returned a streaming P95 of 16.6 ms and a completion max of 35–44 ms (baseline: 35–49 ms).

Expanding and collapsing while output is still arriving can still hitch: the uninstrumented streaming P99 was 45.8–56.0 ms across the three fixed toggle runs (baseline: 46.8–53.3 ms). This fix targets completion, not the cost of opening the panel mid-stream.

#### Realtime Engine Lifecycle (Local Release, iPhone 15 Plus)

In one VM Tracker + Time Profiler capture, two 18-second replays of cached Nemotron 1120 ms each processed the full input and returned 324 final transcript characters. Engine checkout took 25.59 s in the fresh process and 0.015 ms on restart with the warm engine. First recognition took 1.52 s and 1.49 s after the audio feed began, respectively. Physical footprint after stop was 1,520.7 MiB and 1,520.9 MiB. Purging the idle engine dropped it to 681.3 MiB after two seconds, still above the 10.9 MiB pre-load sample. This confirms warm reuse and partial release, not a return to baseline or the absence of a leak. The fresh-process Core ML load, residual footprint, real background eviction, and model switching remain separate profiling targets.

### 5. Live Network Inspector & Instruments Signposts

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
