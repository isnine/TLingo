---
status: current
owner: ios
verified_commit: 41209950853f44b71c5103aedd08995e8b0328e3
review_triggers:
  - translation request lifecycle changes
  - realtime lifecycle changes
  - history persistence changes
  - configuration or language resolution changes
---

# iOS Invariants

## Translation Requests

- Every user action creates an immutable request context and generation.
- Main requests, provider tasks, per-card retry, diff generation and History writes use the same generation.
- A previous generation cannot update cards, History or satisfaction state after a new request starts.
- Completion waits for every selected provider to reach a terminal state.
- Non-cancellation request setup failures, including trial device registration, produce a per-model failure result rather than leaving a running card.
- Model selection resolves only models supported by the requested capability.
- Context Chat selects a chat-capable model, never a direct translation engine. Continuing a result retains its original request languages, including after a window handoff.
- Apple Foundation Model selection requires `SystemLanguageModel.default.availability == .available`; a later availability change keeps the preference but returns an inline provider error.
- On-device Foundation Model requests never use the Worker and do not count toward the free cloud-model limit.
- Private Cloud Compute selection requires `PrivateCloudComputeLanguageModel.availability == .available`; the App Store app and translation extension carry the managed PCC entitlement, PCC never uses the Worker, and the selection remains enabled when quota or service errors occur.

## Default Translation Onboarding

- Opening the translation extension unlocks Continue; it never advances the onboarding page automatically.
- During the trial, the extension invocation notification immediately triggers the existing celebration overlay in the main app, independently of translation completion. Its toast sits below the top safe area so it remains visible above the extension sheet. The extension UI remains unchanged.

## Language Resolution

- Detection equivalence and translation equivalence are separate concepts.
- `zh-Hans` and `zh-Hant` are distinct translation languages.
- The target language is never silently replaced because source detection matched its base language.
- Persistent language identity uses stable identifiers, not localized display text.
- Keyboard language swaps use the same source/target resolution as requests and previews. Minimal detected identifiers retain their script/region meaning when mapped to app language options.

## App Input Delivery

- Services, text deep links and Quick Translate handoffs persist the newest pending request in `HomeInputRouter` until the destination Home is mounted.
- A request activates its destination before it is consumed, and is delivered to one receiver only. Popup results-only and extension views do not consume main-app input.
- macOS Quick Translate presents the same required cloud consent as Home; Direct retains its existing consent bypass.
- The Main App hotkey preserves the hide toggle and uses the main-window creation path when no window exists.

## Realtime

- Every start creates an immutable session token captured by that run's tasks and callbacks.
- macOS captures each realtime audio source once and fans it out to shared recognition and Azure nodes; adding a lane must not create another capture session.
- macOS live capture starts before local model loading completes and buffers at most 15 seconds for ordered replay once recognition nodes are ready.
- Recognition nodes are shared by model ID. Each lane owns separate transcript, translation, caption and History state.
- Imported audio is read once at its original pace and fed through the same recognition and Azure fanout as live capture.
- MOSS is a non-streaming, import-only recognition node. One file-level MOSS task is shared by every MOSS lane, and completion waits for both streamed audio and MOSS translation work.
- On Macs below 24 GB RAM, imported FluidAudio lanes finish and unload before the shared MOSS task starts.
- A lane using the `None` translation provider must remain source-only across captions and History and must not schedule translation work.
- Realtime supports at most three active macOS lanes. Existing lane configurations are immutable while running, and a newly added lane starts at its actual activation offset without replay.
- Macs below 24 GB RAM may run one local streaming recognition model (FluidAudio or Confucius4 R2T2), Macs below 32 GB may run two, and Macs with at least 32 GB may run three.
- The primary lane is the compatibility projection for floating captions, menu bar controls and legacy single-track fields.
- Callback handling validates the token against the active session before changing state.
- Stop order is: reject new input, stop and drain producers, finalize recognition, drain translation, finish recordings, persist, publish terminal state.
- iPhone Audio stop commands and producer snapshots have separate session-scoped ownership. A stale producer cannot clear a newer stop command or replace the active session; published terminal snapshots cannot be overwritten by later callbacks.
- Both ReplayKit stop routes drain before terminal publication. The synchronous system callback waits for a bounded drain; an unfinished drain remains stopping, and extension disappearance is reported as failure rather than fabricated success.
- `stopped` and `failed` are terminal for a session token.
- Clear-display and start-new-session are different commands.
- Recognition and translation buffers have explicit memory and duration bounds.
- Parakeet EOU 320/1280, English Nemotron 560/1120/2240, and Nemotron 3.5 Multilingual 2240 share one realtime adapter and must flush with `finish()` before a session becomes terminal.
- iOS offers only Parakeet EOU 320, Nemotron 1120, and Nemotron 3.5 Multilingual 2240 as downloadable models; the other English variants are macOS-only and their iOS caches are removed.
- Downloaded recognition models live in Application Support `RecognitionModels/` (excluded from backup; migrated from Caches). Interrupted FluidAudio downloads keep their files so retries resume, and a model counts as cached only when every compiled bundle has `model.mil`, `coremldata.bin`, and `weights/weight.bin` and no `.partial` file remains. FluidAudio downloads fall back to `hf-mirror.com` when `huggingface.co` is unreachable.
- Nemotron 3.5 Multilingual uses the full-vocabulary `multilingual/2240ms` variant. Explicit source languages are passed as model prompts; Auto uses model language detection.
- Confucius4 R2T2 (`mlx-community/Confucius4-R2T2-8bit`) runs on MLX with the upstream stable-prefix protocol: 160 ms steps (merged up to 2 s under backlog), a 16 s audio window that drops its oldest 8 s, and one rolled-back token. Committed text is append-only; stop flushes without rollback. The MLX buffer cache is capped at 512 MB.
- The Xcode workspace mirrors `mlx-swift` to the TLingo fork at version `0.31.7`. That fork updates its MLX core submodule to prevent Metal `Gather` from binding a null pointer for empty vector metadata. Keep the mirror and resolved version together until an upstream release includes the fix.
- Streaming partial callbacks replace one pending segment. Stable segments are append-only and retain their IDs after pending promotion.
- Streaming models commit completed sentences at punctuation boundaries. Unpunctuated text looks for likely sentence starts after 20 words, allows weaker boundaries after 32 words, and has a 36-word hard limit. EOU and terminal flush commit the remaining text.
- Recognition callback timing is not an audio-silence signal. Caption and History segmentation must use canonical model state, punctuation, or bounded stable text.
- Model EOU boundaries are durable recognition segments with stable IDs and audio offsets; Caption and History must not flatten them into one string.

## History

- A checkpoint is acknowledged only after persistence succeeds.
- Fetch failure is not equivalent to an empty result.
- History fetch and deletion errors propagate to callers. Failed fetches retain loaded records; failed deletions retain UI rows and roll back pending database changes before any audio cleanup.
- SwiftData records and audio files form one transaction boundary.
- Destructive audio cleanup requires a successfully loaded complete reference set.
- Concurrent writers use revision or field-level merge; a stale whole-session snapshot cannot overwrite newer autosave data.
- Stable segment IDs represent semantic content, not array position.
- Multi-lane realtime History stores one shared audio session with stable track and segment IDs. Legacy `segments` and model fields project the primary track.
- A session without stored tracks projects its legacy `segments` as one track whose ID is the session request ID, so repeated autosaves merge into that track.
- Single-lane History segment offsets come from recognizer audio time (Apple Speech word time ranges, or segment offsets), measured on the same buffers as the recording. Text-arrival time is only a fallback when the recognizer reports no timing.
- macOS recognition nodes translate token timings into the shared audio timeline; lanes exclude pre-activation timings and preserve stable IDs when recognition segments split into multiple History sentences.
- macOS History audio reconstruction adds a source-scoped track; it cannot replace the original realtime track or a track from another audio source.
- Reconstructed segments retain their audio offset, duration and anonymous speaker ID so playback, export and Chat context use the same timeline.
- MOSS diarization is available for macOS Apple Silicon History reconstruction and imported-audio lanes. It is never available for live microphone or Mac Audio capture, and its weights remain an on-demand cache.
- Realtime History title generation runs once after terminal persistence, never during autosave, and updates only the stored session title by request ID.

## Configuration And Voice

- Active configuration selection survives app and extension process startup.
- macOS shortcut persistence preserves key code zero (the A key) with modifiers; only zero key code and zero modifiers together represent an empty shortcut.
- User actions are identified by stable IDs; display-name collision cannot silently delete data.
- Vocabulary mutations resolve normalized term/target identity from a fresh context under a shared app/extension file lock. Bookmark toggles resolve persisted state within that same transaction; no schema migration is required.
- Configuration save success means disk commit succeeded.
- Speech and voice tasks return to an idle or terminal state on success, failure and cancellation.
