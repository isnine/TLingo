The text input on the home and conversation screens: a Liquid Glass surface holding an auto-growing editor and a round send button.

Hand-written from `ios/ShareCore/UI/Home/HomeView.swift` (`inputComposerBackground`) and `ios/ShareCore/UI/Conversation/ConversationInputBar.swift`; glass from `TLingoGlassSurface.swift`.

- **Consumer provides:** the bound text, a placeholder, `canSend`, and the send action.
- **Anatomy:** `tlingoGlassSurface(.chrome, cornerRadius: TLingoRadius.large)` (`radius-18`); `space-16` × `space-8` padding; editor in 16 regular. The conversation bar uses a glass capsule instead.
- **Send button:** `tlingoGlassCircle(canSend ? .prominent : .control)` — `accent-fill` with an `on-accent` arrow when sendable, neutral control glass when not. The conversation bar uses the same button (it was previously `text-primary`); stop uses `.destructive`.
- **Fallback (< iOS/macOS 26):** ultra-thin material + `card-background` at 72% light / 16% dark + 1px `divider` stroke — what this preview renders.
