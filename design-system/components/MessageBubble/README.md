Messages in the follow-up chat: the user's turns sit in a quiet bubble; the model's replies are unboxed Markdown.

Hand-written from `ios/ShareCore/UI/Conversation/MessageBubbleView.swift`.

- **Consumer provides:** the message (role, Markdown text, timestamp) and speak/copy handlers.
- **Anatomy:** user bubble `chip-secondary-background`, `radius-12`, `space-12` × `space-8` padding; assistant text full-width in `text-primary` with the Markdown results styles; timestamps `footnote` `text-secondary`.
- **Quoted source:** `label` in `text-secondary`, indented 10 with a 2px `divider` rule.
- A 6px `accent` dot marks a reply still streaming.
