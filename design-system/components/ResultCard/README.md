A solid card holding one model's answer, streamed as Markdown, with its status, metadata and actions.

Hand-written from `ios/ShareCore/UI/Components/ProviderResultCardView.swift`; the outlined home variant from `HomeView.swift`.

- **Consumer provides:** the run (status: streaming / success / failure, text, model name, duration) and handlers for copy, replace, speak, retry and chat.
- **Anatomy:** `card-background`, `radius-12`, `space-16` padding (`space-8` in compact snapshots). Body uses the Markdown results styles (`md-body` in compact). Metadata in `footnote` `text-secondary`; actions in `footnote` medium `accent`.
- **States:** streaming shows `skeleton` lines until the first tokens; success adds a `success` checkmark; failure shows an `error` icon + title (`label`) and a Retry action.
- **Variant:** on the home screen the card is outlined — 1px `divider`, `radius-12`, `space-16` padding — and enters with opacity + scale 0.98 (opacity only when Reduce Motion is on).
- **Don't** add a shadow or glass; results are always solid.
