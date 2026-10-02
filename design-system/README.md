TLingo is a calm, native-feeling translator for iPhone, iPad and Mac. The interface stays quiet — neutral surfaces, system type, Liquid Glass chrome — so the user's text and the model's answer are the loudest things on screen. One accent colour, chosen by the user, marks everything that is selected or actionable.

## Content fundamentals

- **Short, plain, verb-first.** Buttons and chips are one or two words in Title Case: “Translate”, “Polish”, “Collapse”, “Retry”. Section labels end with a colon: “Target language:”.
- **Address the user as “you”** in onboarding and prompts; never “we” in the UI.
- **No emoji, no exclamation marks** in interface copy. Status is carried by an SF Symbol plus a word.
- **Every string is localized** (String Catalogs). Leave room for 30% longer labels; chips use `lineLimit(1)` with a 0.88 minimum scale factor rather than truncating mid-word.
- **Language names are shown in their own script** where possible (English → 简体中文), joined by an arrow.

## Visual foundations

### Colour

- Ground every screen in `background`. Put content on `card-background` (results) or `input-background` (fields, picker rows).
- Text is `text-primary` on those three grounds; secondary information uses `text-secondary`. Never put `text-secondary` on a tinted chip.
- `accent` is **not a fixed brand colour**: it resolves to the user's accent theme (`accent-orange` Sunset, `accent-blue` Ocean — the default, `accent-purple`, `accent-pink`, `accent-green`, `accent-red`, `accent-teal`, `accent-indigo`). Each theme has a base and a `-strong` variant. `accent` resolves to `-strong` in light mode (legible on white) and the base in dark mode. Always reference `accent` / `accent-fill`, never one of the eight directly, except in the theme picker itself.
- Use `accent` for text and icons: links, result actions, the language-direction arrow, the “Target language:” label, progress tints.
- Use `accent-fill` + `on-accent` for anything filled: the selected action chip, send buttons, primary capsules, the primary metadata chip. Never put white on plain `accent`.
- Unselected chips and user message bubbles sit on `chip-secondary-background`.
- `success` and `error` only appear with an icon (checkmark / exclamation) and a word; they are never the only signal.
- Every `-strong` variant keeps white text at or above 4.5:1. Never use a raw `.red` / `.white`: stop and speaking states use `error`, text on fills uses `on-accent`.

### Type

- One family: the system font (`sans` — SF Pro on Apple platforms). No custom fonts are shipped. Code uses `mono` (SF Mono).
- Interface sizes are small and dense: `body` (14) is the default, `label` / `label-strong` (13) for labels, `footnote` (12) for metadata, `chip` (14 medium) on chips. Weights are 400, 500 and 600; 700 only for `display` and `title-1`.
- Model output is Markdown, rendered with the **Markdown results** styles at 1.4 line height (headings 1.3). Three presets scale it: compact (`md-body` 15), detail (`md-body-detail` 16), prominent (`md-body-prominent` 19). All of it respects Dynamic Type on iOS.

### Spacing & layout

- Spacing runs on a 4pt rhythm: 4, 8, 12, 16, 20, 24 (`TLingoSpacing.xxs`…`xl`). `space-8` and `space-12` are the workhorses. Older views still carry off-grid values; snap them when you touch them.
- Screens have `space-20` horizontal margins; result cards pad `space-16` (compact snapshot: `space-8`).
- Action chips sit in a horizontally scrolling row, `space-12` apart.

### Shape

- Corners are continuous (squircle) rounded rectangles. Four steps only (`TLingoRadius`): `radius-8` small controls and thumbnails, `radius-12` cards, bubbles and rows, `radius-18` composer, language bar and floating panels, `radius-24` large docked bars. Always `style: .continuous`.
- Chips, language pills and small buttons are **capsules** (`radius-pill`). Round icon buttons (send, swap) are circles.

### Surfaces, glass and elevation

- Floating chrome uses **Liquid Glass** on iOS/macOS 26 through one of five named styles — never hand-tuned opacities:
  - `.chrome` — bars and containers (composer, language bar, conversation input).
  - `.control` — neutral tappable glass (chips, icon buttons, secondary capsules).
  - `.panel` — floating panels and prompts carrying their own content.
  - `.prominent` — the primary action, filled with `accent-fill`.
  - `.destructive` — stop / end actions, filled with `error`.
  Call `tlingoGlassSurface(_:cornerRadius:interactive:)`, `tlingoGlassCapsule(_:interactive:)` or `tlingoGlassCircle(_:interactive:)`; pass `interactive: true` when tappable.
- Before 26, the same call falls back to `.ultraThinMaterial` + the style's `card-background` tint + a 1px `divider` stroke. With **Reduce Transparency** on, the material is replaced by an opaque `card-background`. The web previews in this system show the fallback.
- Keep glass on the floating layer only, never glass on glass; group neighbouring glass controls in a `GlassEffectContainer`.
- Content (results, messages) is **solid**, never glass. Result cards are flat: `card-background`, no shadow; on the home screen they add a 1px `divider` outline.
- Shadows only lift windows that float over other apps: `shadow-popup`, `shadow-overlay`, `shadow-prompt`, `shadow-banner`, `shadow-caption`. Paywall plans use `shadow-accent-glow`.

### Motion

- Results appear with opacity + scale from 0.98; with **Reduce Motion** on they only fade. Streaming text animates in token by token. Toasts auto-dismiss after 10 seconds. Keep motion short and system-like; no bounces on content.

## Iconography

- **SF Symbols only**, rendered at the size of the adjacent text (`micro` 10 in metadata chips, 13–14 elsewhere) and the same colour as the label. Common ones: `chevron.up` / `chevron.down`, `arrow.right` (language direction), `arrow.up` (send), `checkmark.circle.fill`, `exclamationmark.triangle`, `doc.on.doc` (copy), `speaker.wave.2`.
- SF Symbols cannot be redistributed, so this system ships no icon files; on the web substitute an outline icon set at matching weight and flag it.
- The app icon (Assets ▸ Logos) is a magnifying glass over Arabic script — the product mark. Use it as-is on a white tile; there is no separate wordmark, so set “TLingo” in `sans` semibold.

## Components

Every component here is a **static HTML rendition** of the SwiftUI view, hand-written from the source file named in its guidelines and styled by `components/bundle.css` (classes prefixed `tl-`). There is no JavaScript bundle — the real components are SwiftUI.
