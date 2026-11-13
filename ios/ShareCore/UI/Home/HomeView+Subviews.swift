//
//  HomeView+Subviews.swift
//  TLingo
//

import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

#if os(iOS)
    struct TranslationResultDetailView: View {
        @Environment(\.colorScheme) private var colorScheme

        let sourceText: String
        let actionName: String?
        let actionIcon: String?
        let modelDisplayName: String
        let durationText: String?
        let result: HomeViewModel.ModelRunViewState.SuccessResult

        @ThemeColors private var colors: AppColorPalette

        private var resultText: String {
            result.supplementalTexts.isEmpty ? result.text : result.copyText
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sourceSection
                    resultSection
                    supplementalSection
                }
                .padding(20)
            }
            .background(colors.background.ignoresSafeArea())
            .navigationTitle("Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        PasteboardHelper.copy(result.copyText)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
        }

        private var sourceSection: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(sourceText)
                    .font(.system(size: 16))
                    .foregroundStyle(colors.textPrimary)
                    .textSelection(.enabled)

                metadataRow
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sectionBackground)
        }

        private var metadataRow: some View {
            HStack(spacing: 8) {
                if let actionName, !actionName.isEmpty {
                    MetadataChipView(actionName, icon: actionIcon ?? "bolt.fill")
                }
                MetadataChipView(modelDisplayName, icon: "cpu")
                if let durationText {
                    MetadataChipView(durationText, icon: "timer")
                }
            }
        }

        @ViewBuilder
        private var resultSection: some View {
            if !result.sentencePairs.isEmpty {
                detailSection(title: "Translation") {
                    sentencePairsView
                }
            } else if let diff = result.diff {
                detailSection(title: "Result") {
                    diffView(diff)
                }
            } else {
                detailSection(title: "Result") {
                    CompactMarkdownContent(text: resultText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        @ViewBuilder
        private var supplementalSection: some View {
            if !result.supplementalTexts.isEmpty {
                detailSection(title: "More") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(result.supplementalTexts.enumerated()), id: \.offset) { entry in
                            CompactMarkdownContent(text: entry.element)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }

        private var sentencePairsView: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(result.sentencePairs.enumerated()), id: \.offset) { index, pair in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pair.original)
                            .font(.system(size: 14))
                            .foregroundStyle(colors.textSecondary)
                            .textSelection(.enabled)
                        Text(pair.translation)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(colors.textPrimary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 8)

                    if index < result.sentencePairs.count - 1 {
                        Divider()
                    }
                }
            }
        }

        private func diffView(_ diff: TextDiffBuilder.Presentation) -> some View {
            StyledDiffView(diff: diff)
        }

        private func detailSection<Content: View>(
            title: String,
            @ViewBuilder content: () -> Content
        ) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.textSecondary)
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sectionBackground)
        }

        private var sectionBackground: some View {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colors.cardBackground)
        }
    }
#endif

// MARK: - Shimmer Animation

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        gradient: Gradient(colors: [.clear, .white.opacity(0.4), .clear]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 0.6)
                    .offset(x: -geometry.size.width * 0.3 + phase * geometry.size.width * 1.6)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

private struct ViewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    @ViewBuilder
    func homeNavigationChrome(usesNativeNavigationHeader: Bool, colors: AppColorPalette) -> some View {
        #if os(macOS)
            toolbarBackground(.hidden, for: .windowToolbar)
        #elseif os(iOS)
            if usesNativeNavigationHeader {
                navigationTitle("Text")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.visible, for: .navigationBar)
                    .toolbarBackground(colors.background, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            } else {
                toolbar(.hidden, for: .navigationBar)
            }
        #else
            self
        #endif
    }

    /// Cuts HomeView's modifier chain at stable seams. Without it the fully nested type makes the Swift
    /// runtime demangle huge metadata names on the first frame (~200 ms on an iPhone 15 Plus).
    func erasedForLaunch() -> AnyView {
        AnyView(self)
    }

    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }

    func onHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(key: ViewHeightPreferenceKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(ViewHeightPreferenceKey.self, perform: action)
    }
}

#Preview {
    HomeView(context: nil)
        .preferredColorScheme(.dark)
}

#if os(macOS)
    public extension Notification.Name {
        /// Notification posted by AppleTranslationWindowManager to register a HomeViewModel
        /// with the hidden translation window bridge. userInfo["register"] is (HomeViewModel) -> Void.
        static let appleTranslationViewModelRegister = Notification.Name("appleTranslationViewModelRegister")
    }
#endif

/// A lightweight snapshot so Home doesn't hold SwiftData models.
struct HomeRecentRecord: Identifiable, Equatable {
    let id: UUID
    let sourceText: String
    let resultText: String?

    init(_ record: TranslationRecord) {
        id = record.id
        sourceText = record.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Results are Markdown; the preview shows the first line as plain text.
        resultText = record.modelResults.first?.resultText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { line in
                let plain = (try? AttributedString(markdown: String(line))).map { String($0.characters) }
                return (plain ?? String(line)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }
}

extension View {
    /// Each flat result sits on its own card so results separate by spacing instead of dividers.
    func flatResultCard(colors: AppColorPalette) -> some View {
        padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: TLingoRadius.medium, style: .continuous)
                    .fill(colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: TLingoRadius.medium, style: .continuous)
                            .stroke(colors.divider, lineWidth: 1)
                    )
            )
    }
}
