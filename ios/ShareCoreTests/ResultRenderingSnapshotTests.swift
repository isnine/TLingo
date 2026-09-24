#if os(macOS) || os(iOS)
    #if os(iOS)
        import UIKit
    #elseif os(macOS)
        import AppKit
    #endif
    import SnapshotTesting
    import SwiftUI
    import XCTest

    @testable import ShareCore

    @MainActor
    final class ResultRenderingSnapshotTests: XCTestCase {
        private var originalAccentTheme: AccentTheme?

        override func setUp() {
            super.setUp()
            originalAccentTheme = AppPreferences.shared.accentTheme
            AppPreferences.shared.setAccentTheme(.default)
        }

        override func tearDown() {
            if let originalAccentTheme {
                AppPreferences.shared.setAccentTheme(originalAccentTheme)
            }
            super.tearDown()
        }

        func testCompactMarkdownContent() {
            assertResultSnapshot(
                of: CompactMarkdownContent(text: Self.markdownSample),
                height: 390
            )
        }

        func testStyledDiffView() throws {
            let diff = try XCTUnwrap(Self.diffPresentation)

            assertResultSnapshot(
                of: StyledDiffView(diff: diff),
                height: 250
            )
        }

        func testProviderResultCardMarkdownContent() {
            assertResultSnapshot(
                of: ResultCardSnapshotContent(
                    run: Self.markdownRun,
                    hasDiff: false,
                    isShowingDiff: false
                ),
                height: 500
            )
        }

        func testProviderResultCardDiffContent() throws {
            let run = try XCTUnwrap(Self.diffRun)

            assertResultSnapshot(
                of: ResultCardSnapshotContent(
                    run: run,
                    hasDiff: true,
                    isShowingDiff: true
                ),
                height: 370
            )
        }

        #if os(macOS)
            func testConversationSidebarLayout() {
                assertConversationSidebarSnapshot(colorScheme: .light, named: "macOS-light")
                assertConversationSidebarSnapshot(colorScheme: .dark, named: "macOS-dark")
            }
        #endif

        private func assertResultSnapshot<Content: View>(
            of content: Content,
            height: CGFloat,
            file: StaticString = #filePath,
            testName: String = #function,
            line: UInt = #line
        ) {
            let size = CGSize(width: 390, height: height)
            #if os(iOS)
                let traits = UITraitCollection { mutableTraits in
                    mutableTraits.displayScale = 3
                    mutableTraits.preferredContentSizeCategory = .medium
                    mutableTraits.userInterfaceStyle = .light
                }

                assertSnapshot(
                    of: SnapshotHost(content: content),
                    as: .image(
                        precision: 0.99,
                        perceptualPrecision: 0.98,
                        layout: .fixed(width: size.width, height: size.height),
                        traits: traits
                    ),
                    named: "iOS",
                    timeout: 10,
                    file: file,
                    testName: testName,
                    line: line
                )
            #elseif os(macOS)
                let hostingView = NSHostingView(rootView: SnapshotHost(content: content))
                hostingView.frame = CGRect(origin: .zero, size: size)
                hostingView.appearance = NSAppearance(named: .aqua)
                hostingView.layoutSubtreeIfNeeded()

                assertSnapshot(
                    of: hostingView,
                    as: .image(
                        precision: 0.99,
                        perceptualPrecision: 0.98,
                        size: size
                    ),
                    named: "macOS",
                    timeout: 10,
                    file: file,
                    testName: testName,
                    line: line
                )
            #endif
        }

        #if os(macOS)
            private func assertConversationSidebarSnapshot(
                colorScheme: ColorScheme,
                named: String,
                file: StaticString = #filePath,
                testName: String = #function,
                line: UInt = #line
            ) {
                let size = CGSize(width: 320, height: 640)
                let content = ConversationSidebarSnapshotContent(session: Self.conversationSession)
                let hostingView = NSHostingView(rootView: SnapshotHost(content: content, colorScheme: colorScheme))
                hostingView.frame = CGRect(origin: .zero, size: size)
                hostingView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
                hostingView.layoutSubtreeIfNeeded()

                assertSnapshot(
                    of: hostingView,
                    as: .image(
                        precision: 0.99,
                        perceptualPrecision: 0.98,
                        size: size
                    ),
                    named: named,
                    timeout: 10,
                    file: file,
                    testName: testName,
                    line: line
                )
            }
        #endif

        private static let snapshotModel = ModelConfig(
            id: "snapshot-gpt",
            displayName: "GPT Snapshot",
            isDefault: true,
            isPremium: false
        )

        private static let markdownSample = """
        # Better Translation
        > Use this when replying to a customer.

        - Keep the **deadline** explicit.
        - Mention `invoice_id` only when it helps.
        - Link to [the reference](https://example.com) when context is missing.
        """

        private static let supplementalSample = """
        ### Notes
        - Tone is direct and polite.
        - The inline `deadline` keyword stays visible for scanning.
        """

        private static let markdownRun = HomeViewModel.ModelRunViewState(
            model: snapshotModel,
            status: .success(.init(
                text: markdownSample,
                copyText: markdownSample,
                duration: 1.3,
                supplementalTexts: [supplementalSample],
                suggestedActions: ["Make it shorter", "Use formal tone"]
            ))
        )

        private static let diffPresentation = TextDiffBuilder.build(
            original: "Please send report tomorrow morning. It is very good and fast.",
            revised: "Please send the quarterly report tomorrow morning. It is clear and actionable."
        )

        private static var diffRun: HomeViewModel.ModelRunViewState? {
            guard let diff = diffPresentation else { return nil }
            return HomeViewModel.ModelRunViewState(
                model: snapshotModel,
                status: .success(.init(
                    text: "Please send the quarterly report tomorrow morning. It is clear and actionable.",
                    copyText: "Please send the quarterly report tomorrow morning. It is clear and actionable.",
                    duration: 0.9,
                    diff: diff
                ))
            )
        }

        private static let conversationSession = ConversationSession(
            model: snapshotModel,
            action: ActionConfig(
                name: "Translate",
                prompt: "Translate the text below from English to Chinese, Simplified.",
                outputType: .translate
            ),
            availableModels: [
                snapshotModel,
                ModelConfig(id: "snapshot-fast", displayName: "Fast Snapshot", isDefault: false, isPremium: false),
            ],
            messages: [
                ChatMessage(
                    role: "system",
                    content: "Translate the text below from English to Chinese, Simplified. Preserve tone, meaning, Markdown, and formatting."
                ),
                ChatMessage(
                    role: "user",
                    content: "Could you make this sound clear and natural for a first-time user?"
                ),
                ChatMessage(
                    role: "assistant",
                    content: "你可以把这句话改得更清楚、更自然，让第一次使用的用户也能轻松理解吗？"
                ),
                ChatMessage(
                    role: "user",
                    content: "Make it shorter."
                ),
            ]
        )
    }

    private struct SnapshotHost<Content: View>: View {
        let content: Content
        var colorScheme: ColorScheme = .light

        var body: some View {
            content
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AppColors.Palette(colorScheme: colorScheme).background)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.colorScheme, colorScheme)
                .dynamicTypeSize(.medium)
        }
    }

    private struct ResultCardSnapshotContent: View {
        let run: HomeViewModel.ModelRunViewState
        let hasDiff: Bool
        let isShowingDiff: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                ResultContentView(
                    run: run,
                    hasDiff: hasDiff,
                    isShowingDiff: isShowingDiff,
                    onToggleDiff: {},
                    isSpeaking: false,
                    onSpeak: {},
                    onStopSpeaking: {},
                    onCopy: { _ in },
                    onReplace: nil,
                    onChat: {},
                    onSuggestedAction: { _ in },
                    onInspectRequest: nil
                )
                ResultBottomInfoBar(
                    run: run,
                    showModelName: true,
                    hasDiff: hasDiff,
                    isShowingDiff: isShowingDiff,
                    onToggleDiff: {},
                    isSpeaking: false,
                    onSpeak: {},
                    onStopSpeaking: {},
                    onRetry: {},
                    onCopy: { _ in },
                    onReplace: nil,
                    onChat: {}
                )
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppColors.Palette(colorScheme: .light).cardBackground)
            )
        }
    }

    #if os(macOS)
        private struct ConversationSidebarSnapshotContent: View {
            @Environment(\.colorScheme) private var colorScheme

            private let messages: [ChatMessage]

            private var colors: AppColorPalette {
                AppColors.palette(for: colorScheme)
            }

            init(session: ConversationSession) {
                messages = session.messages
            }

            var body: some View {
                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        ForEach(messages) { message in
                            MessageBubbleView(message: message)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    Spacer(minLength: 0)

                    Divider()
                        .foregroundColor(colors.divider)

                    ConversationInputSnapshotBar()
                }
                .background(colors.background)
            }
        }

        private struct ConversationInputSnapshotBar: View {
            @Environment(\.colorScheme) private var colorScheme

            private var colors: AppColorPalette {
                AppColors.palette(for: colorScheme)
            }

            var body: some View {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(colors.cardBackground.opacity(colorScheme == .dark ? 0.16 : 0.72)))
                        .overlay(Circle().stroke(colors.divider, lineWidth: 1))

                    HStack(spacing: 4) {
                        Text("Ask for follow-up changes")
                            .font(.system(size: 14))
                            .foregroundColor(colors.textSecondary.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 12)

                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(colors.textSecondary.opacity(0.45))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(colors.chipSecondaryBackground.opacity(0.45)))
                            .padding(4)
                    }
                    .frame(minHeight: 40)
                    .background(
                        Capsule(style: .continuous)
                            .fill(colors.cardBackground.opacity(colorScheme == .dark ? 0.16 : 0.72))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(colors.textSecondary.opacity(0.25), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 16)
            }
        }
    #endif
#endif
