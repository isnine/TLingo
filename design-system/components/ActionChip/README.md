A capsule button that picks which action (Translate, Polish, Grammar Check…) runs on the input text.

Hand-written from `ios/ShareCore/UI/Home/HomeView.swift` (`actionChipsStack`) and `ActionChipsView.swift`.

- **Consumer provides:** the list of actions (`displayName`, `id`), the selected id, and a tap handler.
- **Anatomy:** `chip` text (14 medium), `space-16` horizontal padding (10 vertical, keeps the chip near 40pt tall), `radius-pill`; chips sit `space-12` apart in a horizontal scroll row.
- **States:** selected → `accent-fill` / `on-accent` (via `chip-primary-background` / `chip-primary-text`); unselected → `card-background` at 78% (light) or `chip-secondary-background` at 72% (dark) with `text-primary`.
- **Do** keep labels to one or two words, one line, scaling to 0.88 before truncating. **Don't** use more than one selected chip at a time.
