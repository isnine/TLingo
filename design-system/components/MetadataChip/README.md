A tiny capsule showing one fact about a result — model, latency, token count — with an SF Symbol.

Hand-written from `ios/ShareCore/UI/Components/MetadataChipView.swift`.

- **Consumer provides:** `text`, an SF Symbol name `icon`, and `isPrimary`.
- **Anatomy:** symbol at `micro` (10) + `footnote` (12) text, `space-4` gap, `space-8` × `space-4` padding, `radius-pill`.
- **States:** default `text-secondary` on `chip-secondary-background`; primary `on-accent` on `accent-fill` (only for the model name).
- Icons in this preview are stand-ins for SF Symbols.
