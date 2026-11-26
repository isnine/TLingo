import SwiftUI

#if os(iOS)
    import UIKit

    enum LongTextResultMode: Hashable {
        case reading
        case compare
    }

    extension HomeView {
        static let longTextLineThreshold = 8

        static func paragraphs(of text: String) -> [String] {
            text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        /// Long translations read one model at a time; the threshold uses rendered height, not character count.
        var usesLongTextResults: Bool {
            guard usesPhoneComposerChrome, context == nil, viewModel.displayedModelRuns.count > 1 else { return false }
            if Self.paragraphs(of: viewModel.currentRequestInputText).count >= 2 {
                return true
            }
            let threshold = UIFont.preferredFont(forTextStyle: .body).lineHeight * CGFloat(Self.longTextLineThreshold)
            return viewModel.displayedModelRuns.contains { (resultContentHeights.values[$0.id] ?? 0) > threshold }
        }

        var longTextRuns: [HomeViewModel.ModelRunViewState] {
            viewModel.displayedModelRuns
        }

        var longTextSelectedRun: HomeViewModel.ModelRunViewState? {
            longTextRuns.first { $0.id == longTextSelectedRunID } ?? longTextRuns.first
        }

        func successText(of run: HomeViewModel.ModelRunViewState) -> String? {
            if case let .success(result) = run.status {
                return result.copyText
            }
            return nil
        }

        var longTextParagraphCount: Int {
            Self.paragraphs(of: viewModel.currentRequestInputText).count
        }

        var longTextResultsPanel: some View {
            VStack(alignment: .leading, spacing: TLingoSpacing.md) {
                Picker(selection: $longTextMode) {
                    Text("Reading").tag(LongTextResultMode.reading)
                    Text("Compare").tag(LongTextResultMode.compare)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("home_long_text_mode")

                switch longTextMode {
                case .reading:
                    longTextReadingView
                case .compare:
                    longTextCompareView
                }
            }
            .onChange(of: viewModel.currentRequestInputText) { resetLongTextState() }
        }

        // MARK: - Reading

        var longTextReadingView: some View {
            VStack(alignment: .leading, spacing: TLingoSpacing.md) {
                ScrollView(.horizontal) {
                    HStack(spacing: TLingoSpacing.sm) {
                        ForEach(longTextRuns) { run in
                            let isSelected = run.id == longTextSelectedRun?.id
                            Button {
                                longTextSelectedRunID = run.id
                            } label: {
                                Text(run.modelDisplayName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(isSelected ? colors.onAccent : colors.textPrimary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        isSelected ? colors.accentFill : colors.chipSecondaryBackground,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                }
                .scrollIndicators(.hidden)

                longTextSourceCard

                if let run = longTextSelectedRun {
                    content(for: run, textPreset: .compact, showsInlineActions: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .flatResultCard(colors: colors)
                        .id(run.id)
                }
            }
        }

        var longTextSourceCard: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.currentRequestInputText)
                    .font(.subheadline)
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(isLongTextSourceExpanded ? nil : 2)
                Button(isLongTextSourceExpanded ? "Collapse" : "Expand") {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        isLongTextSourceExpanded.toggle()
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(colors.accent)
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }

        // MARK: - Compare

        var longTextCompareView: some View {
            let sources = Self.paragraphs(of: viewModel.currentRequestInputText)
            let index = min(longTextParagraphIndex, max(sources.count - 1, 0))
            let selected = longTextSelectedRun
            let selectedParagraph = selected.flatMap(successText(of:)).map(Self.paragraphs(of:))?[safe: index]

            return VStack(alignment: .leading, spacing: TLingoSpacing.sm) {
                if let source = sources[safe: index] {
                    Text(source)
                        .font(.subheadline)
                        .foregroundStyle(colors.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                }

                ForEach(longTextRuns) { run in
                    let paragraph = successText(of: run).map(Self.paragraphs(of:))?[safe: index]
                    let isSelected = run.id == selected?.id
                    if !isSelected, let paragraph, paragraph == selectedParagraph, let selected {
                        HStack(spacing: 6) {
                            Text(run.modelDisplayName)
                                .foregroundStyle(colors.textPrimary)
                            Text("Same as \(selected.modelDisplayName)")
                                .foregroundStyle(colors.textSecondary)
                        }
                        .font(.footnote)
                        .padding(.horizontal, 4)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(run.modelDisplayName), Same as \(selected.modelDisplayName)"))
                    } else {
                        compareParagraphCard(
                            run: run,
                            paragraph: paragraph,
                            reference: isSelected ? nil : selectedParagraph,
                            isSelected: isSelected
                        )
                    }
                }
            }
        }

        func compareParagraphCard(
            run: HomeViewModel.ModelRunViewState,
            paragraph: String?,
            reference: String?,
            isSelected: Bool
        ) -> some View {
            Button {
                longTextSelectedRunID = run.id
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(run.modelDisplayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(colors.textSecondary)
                    if let paragraph {
                        Text(highlightedParagraph(paragraph, reference: reference))
                            .font(.body)
                            .foregroundStyle(colors.textPrimary)
                            .multilineTextAlignment(.leading)
                    } else if isRunLoading(run) {
                        AnimatedEllipsis()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .flatResultCard(colors: colors)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: TLingoRadius.medium, style: .continuous)
                            .strokeBorder(colors.accent, lineWidth: 1.5)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }

        func highlightedParagraph(_ paragraph: String, reference: String?) -> AttributedString {
            guard let reference, let diff = TextDiffBuilder.build(original: reference, revised: paragraph) else {
                return AttributedString(paragraph)
            }
            var result = AttributedString()
            for segment in diff.revisedSegments where segment.kind != .removed {
                var piece = AttributedString(segment.text)
                if segment.kind == .added {
                    piece.backgroundColor = colors.accent.opacity(0.18)
                }
                result += piece
            }
            return result
        }

        // MARK: - Bottom bar

        @ViewBuilder
        var longTextActionsBar: some View {
            switch longTextMode {
            case .reading:
                resultActionsRow(
                    secondary: ("Copy All", "home_copy_all_button", {
                        if let text = longTextSelectedRun.flatMap(successText(of:)) {
                            copyToPasteboard(text)
                        }
                    }),
                    primary: ("New Translation", "home_new_translation_button", { viewModel.inputText = "" })
                )
            case .compare:
                let count = longTextParagraphCount
                resultActionsRow(
                    secondary: ("Previous Paragraph", "home_previous_paragraph_button", {
                        longTextParagraphIndex = max(longTextParagraphIndex - 1, 0)
                    }),
                    primary: ("Next Paragraph", "home_next_paragraph_button", {
                        longTextParagraphIndex = min(longTextParagraphIndex + 1, max(count - 1, 0))
                    })
                )
            }
        }

        func resultActionsRow(
            secondary: (LocalizedStringKey, String, () -> Void),
            primary: (LocalizedStringKey, String, () -> Void)
        ) -> some View {
            HStack(spacing: TLingoSpacing.md) {
                Button(action: secondary.2) {
                    Text(secondary.0)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .tlingoGlassCapsule(.control, interactive: true)
                }
                .foregroundStyle(colors.accent)
                .accessibilityIdentifier(secondary.1)

                Button(action: primary.2) {
                    Text(primary.0)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .tlingoGlassCapsule(.prominent, interactive: true)
                }
                .foregroundStyle(colors.onAccent)
                .accessibilityIdentifier(primary.1)
            }
            .font(.headline)
            .buttonStyle(.plain)
            .frame(maxWidth: bottomComposerContentMaxWidth)
            .frame(maxWidth: .infinity)
        }

        func resetLongTextState() {
            longTextMode = .reading
            longTextSelectedRunID = nil
            longTextParagraphIndex = 0
            isLongTextSourceExpanded = false
        }
    }

    private extension Array {
        subscript(safe index: Int) -> Element? {
            indices.contains(index) ? self[index] : nil
        }
    }
#endif

#if os(macOS)
    extension HomeView {
        var usesLongTextResultsLayout: Bool {
            false
        }

        var longTextResultsPanel: some View {
            EmptyView()
        }
    }
#else
    extension HomeView {
        var usesLongTextResultsLayout: Bool {
            usesLongTextResults
        }
    }
#endif
