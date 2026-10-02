A pair of glass capsules choosing source and target language, joined by an accent direction arrow.

Hand-written from `ios/ShareCore/UI/Components/LanguageSwitcherView.swift`.

- **Consumer provides:** bindings for source and target language, the detected source (if any), and a compact-metrics flag.
- **Anatomy:** each language is a `tlingoGlassCapsule(.control, interactive: true)` with a chevron in `text-secondary`; the arrow between them is `accent`, 16 medium (12 in compact). The bar sits inside a `.chrome` glass surface, `radius-18`.
- **Menus:** the target section label uses `label-strong` in `accent`; others use `text-secondary`.
- Show language names in their own script.
