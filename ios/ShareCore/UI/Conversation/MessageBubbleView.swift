import SwiftStreamingMarkdown
import SwiftUI

/// Displays system context, user bubbles, and transparent assistant responses.
public struct MessageBubbleView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var ttsService = TTSPreviewService.shared
    @State private var isSystemExpanded: Bool = false

    let message: ChatMessage
    let isStreaming: Bool

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    public init(message: ChatMessage, isStreaming: Bool = false) {
        self.message = message
        self.isStreaming = isStreaming
    }

    public var body: some View {
        switch message.role {
        case "system":
            systemBubble
        case "user":
            userBubble
        case "assistant":
            assistantBubble
        default:
            EmptyView()
        }
    }

    // MARK: - System Bubble (tap to expand)

    private var systemBubble: some View {
        Text(message.content)
            .font(.system(size: 12))
            .foregroundColor(colors.textSecondary)
            .lineLimit(isSystemExpanded ? nil : 1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSystemExpanded.toggle()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    // MARK: - User Bubble (right-aligned)

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 24)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.images.isEmpty {
                    ImageAttachmentInline(images: message.images)
                }

                CompactMarkdownContent(text: message.content)
            }
            .bubbleBackground(colors.chipSecondaryBackground)
        }
    }

    // MARK: - Assistant Response

    private var isSpeakingThis: Bool {
        ttsService.isSpeaking(textID: message.id.uuidString)
    }

    private var assistantBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    ThinkingDisclosureView(text: reasoning)
                }

                CompactMarkdownContent(text: message.content)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !isStreaming {
                    HStack(spacing: 12) {
                        Button {
                            if isSpeakingThis {
                                ttsService.stopPlayback()
                            } else {
                                Task {
                                    await ttsService.speak(text: message.content, textID: message.id.uuidString)
                                }
                            }
                        } label: {
                            Image(systemName: isSpeakingThis ? "stop.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 11))
                                .foregroundColor(isSpeakingThis ? colors.error : colors.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help(isSpeakingThis ? "Stop Speaking" : "Speak")
                        .accessibilityLabel(isSpeakingThis ? "Stop Speaking" : "Speak")

                        Button {
                            PasteboardHelper.copy(message.content)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(colors.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy")
                        .accessibilityLabel("Copy")
                    }
                }
            }

            Spacer(minLength: 24)
        }
    }
}

/// Streaming assistant text rendered on the conversation background.
public struct StreamingBubbleView: View {
    @Environment(\.colorScheme) private var colorScheme

    let reasoningText: String
    let text: String
    let reasoningSource: ConversationMarkdownStreamSource
    let source: ConversationMarkdownStreamSource

    public init(
        reasoningText: String,
        text: String,
        reasoningSource: ConversationMarkdownStreamSource,
        source: ConversationMarkdownStreamSource
    ) {
        self.reasoningText = reasoningText
        self.text = text
        self.reasoningSource = reasoningSource
        self.source = source
    }

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                if !reasoningText.isEmpty {
                    ThinkingDisclosureView(
                        text: reasoningText,
                        source: reasoningSource,
                        initiallyExpanded: true,
                        collapsesWhenAnswerStarts: !text.isEmpty
                    )
                }

                StreamedMarkdownView(
                    source: source,
                    config: MarkdownTypography.renderConfig(
                        preset: .compact,
                        textColor: colors.textPrimary,
                        secondaryTextColor: colors.textSecondary,
                        accentColor: colors.accent,
                        animatesText: true
                    )
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(colors.textPrimary)
                .contentDirectionAware(text)

                StreamingIndicator(colors: colors)
            }

            Spacer(minLength: 24)
        }
    }
}

private struct ThinkingDisclosureView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isExpanded: Bool

    let text: String
    let source: ConversationMarkdownStreamSource?
    let collapsesWhenAnswerStarts: Bool

    init(
        text: String,
        source: ConversationMarkdownStreamSource? = nil,
        initiallyExpanded: Bool = false,
        collapsesWhenAnswerStarts: Bool = false
    ) {
        self.text = text
        self.source = source
        self.collapsesWhenAnswerStarts = collapsesWhenAnswerStarts
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Group {
                if let source {
                    StreamedMarkdownView(
                        source: source,
                        config: MarkdownTypography.renderConfig(
                            preset: .compact,
                            textColor: colors.textSecondary,
                            secondaryTextColor: colors.textSecondary,
                            accentColor: colors.accent,
                            animatesText: true
                        )
                    )
                } else {
                    MarkdownContentView(
                        text: text,
                        preset: .compact,
                        textColor: colors.textSecondary
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .contentDirectionAware(text)
        } label: {
            Text("Thinking")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(colors.textSecondary)
        }
        .tint(colors.textSecondary)
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(colors.divider)
                .frame(width: 2)
        }
        .onChange(of: collapsesWhenAnswerStarts) { _, shouldCollapse in
            if shouldCollapse {
                isExpanded = false
            }
        }
    }
}

private struct StreamingIndicator: View {
    let colors: AppColorPalette
    @State private var opacity: Double = 0.3

    var body: some View {
        Circle()
            .fill(colors.accent)
            .frame(width: 6, height: 6)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    opacity = 1.0
                }
            }
    }
}

private extension View {
    func bubbleBackground(_ fill: Color) -> some View {
        padding(.horizontal, TLingoSpacing.sm)
            .padding(.vertical, TLingoSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: TLingoRadius.medium, style: .continuous)
                    .fill(fill)
            )
    }
}
