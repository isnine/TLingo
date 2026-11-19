//
//  HomeView+Results.swift
//  TLingo
//

import os
import SwiftStreamingMarkdown
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif
#if os(iOS)
    import TranslationUIProvider
#endif

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "HomeView")

extension HomeView {
    // MARK: - Flat result panel

    /// The first result stays in place while the remaining models expand below it.
    func flatResultsPanel(viewportHeight: CGFloat) -> some View {
        let runs = viewModel.displayedModelRuns
        let showsComparison = isComparingResults && runs.count > 1
        #if os(iOS)
            let showsResultOptions = showsFocusedComparison || !viewModel.isWordLookupFallback
        #else
            let showsResultOptions = !viewModel.isWordLookupFallback
        #endif

        let panel = VStack(alignment: .leading, spacing: Self.flatResultCardSpacing) {
            if let primaryRun = runs.first {
                flatResultRow(for: primaryRun, animatesStreamingText: true)
                if runs.count > 1 {
                    let remainingRuns = Array(runs.dropFirst())
                    Group {
                        if showsComparison {
                            expandedComparison(remainingRuns)
                        } else {
                            let previews = Dictionary(
                                uniqueKeysWithValues: remainingRuns.map { run in
                                    (run.id, isAwaitingFirstOutput(run) ? AttributedString() : resultPreview(for: run))
                                }
                            )
                            collapsedResults(
                                remainingRuns,
                                previews: previews,
                                viewportHeight: viewportHeight
                            )
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: showsComparison)
                }
            }

            if !runs.isEmpty, showsResultOptions {
                resultOptionsFooter(showsResultOrder: runs.count > 1)
            }

            if shouldShowInlineSatisfactionPrompt {
                satisfactionPromptResultCell
                    .padding(.top, 6)
            }
        }
        #if os(macOS)
            return panel.onHeightChange { height in
                updateMeasuredHeight(height, current: flatResultsPanelHeight) {
                    flatResultsPanelHeight = $0
                }
            }
        #else
            return panel.onGeometryChange(for: CGFloat?.self) { geometry in
                usesAdaptivePhonePreviews && !showsComparison && runs.count > 1 ? geometry.size.height : nil
            } action: { height in
                guard let height else { return }
                updateMeasuredHeight(height, current: flatResultsPanelHeight) {
                    flatResultsPanelHeight = $0
                }
            }
        #endif
    }

    @ViewBuilder
    func expandedComparison(_ runs: [HomeViewModel.ModelRunViewState]) -> some View {
        #if os(iOS)
            LazyVStack(alignment: .leading, spacing: Self.flatResultCardSpacing) {
                expandedComparisonRows(runs)
            }
        #else
            VStack(alignment: .leading, spacing: Self.flatResultCardSpacing) {
                expandedComparisonRows(runs)
            }
        #endif
    }

    @ViewBuilder
    func expandedComparisonRows(_ runs: [HomeViewModel.ModelRunViewState]) -> some View {
        comparisonHeader(remainingModelCount: runs.count)
        ForEach(runs) { run in
            flatResultRow(for: run, animatesStreamingText: false)
        }
    }

    @ViewBuilder
    func flatResultRow(
        for run: HomeViewModel.ModelRunViewState,
        animatesStreamingText: Bool = true
    ) -> some View {
        let runID = run.id
        let isLoading = isRunLoading(run)
        let row = VStack(alignment: .leading, spacing: 8) {
            flatResultHeader(for: run)
            content(
                for: run,
                textPreset: .compact,
                showsInlineActions: false,
                animatesStreamingText: animatesStreamingText
            )
            .frame(maxWidth: .infinity, minHeight: heldResultHeights[runID], alignment: .topLeading)
            // Outgoing content fades inside the row instead of overlapping the next one.
            .clipped()
            .onHeightChange { height in
                guard !isLoading, heldResultHeights[runID] == nil else { return }
                updateMeasuredHeight(height, current: resultContentHeights.values[runID] ?? 0) {
                    resultContentHeights.values[runID] = $0
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatResultCard(colors: colors)
        .onChange(of: isLoading) { _, loading in
            guard !loading, heldResultHeights[runID] != nil else { return }
            withAnimation(.smooth(duration: 0.35)) {
                heldResultHeights[runID] = nil
            }
        }
        #if DEBUG && os(iOS)
        .background(TranslationFrameProbe(run: run))
        #endif

        #if os(iOS)
            row.modifier(ResultDetailInteraction(isEnabled: isSuccessfulRun(run)) {
                presentResultDetail(runID: runID)
            })
        #else
            // macOS has no result detail sheet; the text stays selectable in place.
            row
        #endif
    }

    func flatResultHeader(for run: HomeViewModel.ModelRunViewState) -> some View {
        HStack(spacing: 8) {
            Text(run.modelDisplayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(colors.textPrimary)
                .lineLimit(1)

            switch run.status {
            case .idle, .running, .streaming, .streamingSentencePairs:
                ProgressView()
                    .controlSize(.mini)
            case .failure:
                Image(systemName: run.status.isUnsupported ? "nosign" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(run.status.isUnsupported ? colors.textPrimary : colors.error)
            case .success:
                EmptyView()
            }

            if DeveloperMode.isEnabled {
                providerInfoButton(runID: run.id)
            }

            Spacer(minLength: 8)

            HStack(spacing: 16) {
                if viewModel.canShowSentencePairs(for: run) {
                    sentencePairsToggle(for: run)
                }

                switch run.status {
                case let .success(result):
                    speakResultButton(text: result.copyText, runID: run.id)
                    // On iPhone the conversation entry lives in the result detail sheet.
                    actionButtons(
                        copyText: result.copyText,
                        runID: run.id,
                        showsChat: !usesPhoneComposerChrome && (!showsOnlyResults || onResultConversation != nil)
                    )
                case .failure where !run.status.isUnsupported:
                    retryButton(runID: run.id)
                default:
                    EmptyView()
                }
            }
        }
    }

    /// Switches this row between the whole translation and sentence pairs; other rows stay as they are.
    func sentencePairsToggle(for run: HomeViewModel.ModelRunViewState) -> some View {
        let isOn = run.presentation == .sentencePairs

        return Button {
            toggleSentencePairs(runID: run.id)
        } label: {
            Image(systemName: "rectangle.split.1x2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isOn ? colors.onAccent : colors.textPrimary)
                .frame(width: 28, height: 22)
                .background {
                    if isOn {
                        Capsule(style: .continuous)
                            .fill(colors.accentFill)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sentence by Sentence")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("home_sentence_pairs_toggle")
    }

    /// Content swaps without a cross-fade; only the row height animates, from the held height
    /// to the new content once it is ready.
    func toggleSentencePairs(runID: String) {
        heldResultHeights[runID] = resultContentHeights.values[runID]
        viewModel.toggleSentencePairs(runID: runID)
        // A cached result is ready now; release the hold after one frame so the height animates.
        if let run = viewModel.modelRuns.first(where: { $0.id == runID }), !isRunLoading(run) {
            DispatchQueue.main.async {
                withAnimation(.smooth(duration: 0.3)) {
                    heldResultHeights[runID] = nil
                }
            }
        }
    }

    func isRunLoading(_ run: HomeViewModel.ModelRunViewState) -> Bool {
        switch run.status {
        case .idle, .running, .streaming, .streamingSentencePairs:
            return true
        case .success, .failure:
            return false
        }
    }

    func speakResultButton(text: String, runID: String) -> some View {
        let isSpeaking = viewModel.isSpeaking(runID: runID)

        return Button {
            if isSpeaking {
                viewModel.stopSpeaking()
            } else {
                viewModel.speakResult(text, runID: runID)
            }
        } label: {
            Image(systemName: isSpeaking ? "stop.fill" : "speaker.wave.2")
                .font(.system(size: 14))
                .foregroundColor(isSpeaking ? colors.accent : colors.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSpeaking ? "Stop Speaking" : "Speak")
    }

    static let collapsedPreviewFontSize: CGFloat = 14
    static let collapsedPreviewLabelFontSize: CGFloat = 12
    static let collapsedPreviewLabelWidthRange: ClosedRange<CGFloat> = 72 ... 150
    static let collapsedPreviewColumnSpacing: CGFloat = 12
    static let collapsedResultsRowSpacing: CGFloat = 10
    static let collapsedResultsVerticalPadding: CGFloat = 14
    static let flatResultCardSpacing: CGFloat = 10

    func collapsedResults(
        _ runs: [HomeViewModel.ModelRunViewState],
        previews: [String: AttributedString],
        viewportHeight: CGFloat
    ) -> some View {
        let finishedCount = runs.filter(isFinishedRun).count
        #if os(iOS)
            let previewHeight = phoneCollapsedPreviewHeight(viewportHeight: viewportHeight)
        #else
            let lineLimits = collapsedPreviewLineLimits(for: runs, previews: previews, viewportHeight: viewportHeight)
        #endif
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                isComparingResults = true
                #if os(iOS)
                    if usesPhoneComposerChrome, usesBottomComposerLayout, !showsOnlyResults {
                        phoneComparisonMode = .expanded
                    }
                #endif
            }
        } label: {
            let header = HStack(spacing: 4) {
                Text("\(runs.count) more models")
                if finishedCount < runs.count {
                    ProgressView()
                        .controlSize(.mini)
                    Text(verbatim: "\(finishedCount)/\(runs.count)")
                        .font(.system(size: 12).monospacedDigit())
                }
                Spacer()
                Text("Compare")
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(colors.textPrimary)
            VStack(alignment: .leading, spacing: Self.collapsedResultsRowSpacing) {
                #if os(iOS)
                    header
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            guard usesAdaptivePhonePreviews else { return }
                            updateMeasuredHeight(height, current: phoneCollapsedResultsHeaderHeight) {
                                phoneCollapsedResultsHeaderHeight = $0
                            }
                        }
                    if let previewHeight {
                        let minimumRowHeight = UIFont.systemFont(ofSize: Self.collapsedPreviewFontSize)
                            .lineHeight.rounded(.up) + Self.collapsedResultsRowSpacing
                        let visibleRuns = Array(runs.prefix(Int(previewHeight / minimumRowHeight)))
                        if !visibleRuns.isEmpty {
                            PhoneCollapsedPreviewLayout(
                                height: previewHeight - Self.collapsedResultsRowSpacing,
                                spacing: Self.collapsedResultsRowSpacing
                            ) {
                                collapsedPreviewRows(visibleRuns, previews: previews, lineLimit: { _ in nil })
                            }
                        }
                    } else {
                        collapsedPreviewRows(runs, previews: previews, lineLimit: { _ in 1 })
                    }
                #else
                    header
                    collapsedPreviewRows(runs, previews: previews, lineLimit: { lineLimits[$0] ?? 1 })
                #endif
            }
            .padding(.vertical, Self.collapsedResultsVerticalPadding)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard abs(size.width - collapsedResultsSize.width) > 0.5
                    || abs(size.height - collapsedResultsSize.height) > 0.5
                else { return }
                collapsedResultsSize = size
            }
            // Outside the measurement so preview line limits see only the text columns.
            .flatResultCard(colors: colors)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home_compare_results_button")
    }

    func collapsedPreviewRows(
        _ runs: [HomeViewModel.ModelRunViewState],
        previews: [String: AttributedString],
        lineLimit: @escaping (String) -> Int?
    ) -> some View {
        let labelWidth = collapsedPreviewLabelWidth(for: runs)
        return ForEach(runs) { run in
            HStack(alignment: .firstTextBaseline, spacing: Self.collapsedPreviewColumnSpacing) {
                Text(run.modelDisplayName)
                    .font(.system(size: Self.collapsedPreviewLabelFontSize, weight: .medium))
                    .foregroundColor(colors.textPrimary)
                    .lineLimit(1)
                    .frame(width: labelWidth, alignment: .leading)
                Group {
                    if isAwaitingFirstOutput(run) {
                        AnimatedEllipsis()
                    } else if case let .streaming(initialText, _) = run.status {
                        CollapsedStreamingPreviewText(
                            preview: run.streamPreview,
                            fallback: MarkdownPreviewText.plainStreamingPreview(from: initialText)
                        )
                    } else {
                        Text(previews[run.id] ?? AttributedString())
                    }
                }
                .font(.system(size: Self.collapsedPreviewFontSize))
                .foregroundColor(colors.textPrimary)
                .lineLimit(lineLimit(run.id))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func resultOptionsFooter(showsResultOrder: Bool) -> some View {
        HStack {
            Spacer()
            Menu {
                resultOptionsMenuContent(showsResultOrder: showsResultOrder)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                    #if os(iOS)
                        if showsResultOrder {
                            Text(preferences.modelResultOrder.title)
                        } else {
                            Text("Result Options")
                        }
                    #else
                        Text("Result Options")
                    #endif
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(colors.textPrimary)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()
            .accessibilityIdentifier("home_result_order")
            #if os(macOS)
                .accessibilityValue(preferences.modelResultOrder.title)
            #endif
        }
        .padding(.top, 4)
    }

    func comparisonHeader(remainingModelCount: Int) -> some View {
        HStack(spacing: 14) {
            Text("\(remainingModelCount) more models")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(colors.textPrimary)

            Spacer()

            #if os(iOS)
                if !showsFocusedComparison {
                    collapseComparisonButton
                }
            #else
                collapseComparisonButton
            #endif
        }
        .frame(minHeight: 28)
        .padding(.top, 4)
        .padding(.horizontal, 4)
    }

    var collapseComparisonButton: some View {
        Button(action: collapseResultComparison) {
            Image(systemName: "chevron.up")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(colors.textPrimary)
        .accessibilityLabel("Collapse")
    }

    func collapseResultComparison() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            isComparingResults = false
            #if os(iOS)
                phoneComparisonMode = nil
            #endif
        }
    }

    /// Model output is Markdown, so previews render its inline styling instead of raw markers.
    func resultPreview(for run: HomeViewModel.ModelRunViewState) -> AttributedString {
        let text: String
        switch run.status {
        case .idle, .running:
            text = String(localized: "Generating...")
        case let .streaming(streamedText, _):
            if streamedText.isEmpty {
                text = String(localized: "Generating...")
            } else {
                let preview = run.streamPreview.text.isEmpty
                    ? MarkdownPreviewText.plainStreamingPreview(from: streamedText)
                    : run.streamPreview.text
                return AttributedString(preview)
            }
        case let .streamingSentencePairs(pairs, _):
            text = pairs.isEmpty
                ? String(localized: "Translating...")
                : pairs.map(\.translation).joined(separator: " ")
        case let .success(result):
            return MarkdownPreviewText.attributed(from: result.copyText)
        case .failure:
            text = run.status.isUnsupported ? String(localized: "Not Supported") : String(localized: "Request Failed")
        }
        return AttributedString(text.replacingOccurrences(of: "\n", with: " "))
    }

    func isAwaitingFirstOutput(_ run: HomeViewModel.ModelRunViewState) -> Bool {
        switch run.status {
        case .idle, .running: true
        case let .streaming(text, _): text.isEmpty
        case let .streamingSentencePairs(pairs, _): pairs.isEmpty
        case .success, .failure: false
        }
    }

    func isFinishedRun(_ run: HomeViewModel.ModelRunViewState) -> Bool {
        switch run.status {
        case .success, .failure: true
        case .idle, .running, .streaming, .streamingSentencePairs: false
        }
    }

    /// Sizes the model-name column to the widest name so names like "Microsoft Translator" are not truncated.
    func collapsedPreviewLabelWidth(for runs: [HomeViewModel.ModelRunViewState]) -> CGFloat {
        #if os(macOS)
            let font = NSFont.systemFont(ofSize: Self.collapsedPreviewLabelFontSize, weight: .medium)
        #else
            let font = UIFont.systemFont(ofSize: Self.collapsedPreviewLabelFontSize, weight: .medium)
        #endif
        let widest = runs.map { ($0.modelDisplayName as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let range = Self.collapsedPreviewLabelWidthRange
        return min(max(range.lowerBound, widest.rounded(.up)), range.upperBound)
    }

    #if os(iOS)
        var usesAdaptivePhonePreviews: Bool {
            usesPhoneComposerChrome && usesBottomComposerLayout && !showsOnlyResults
        }

        func phoneCollapsedPreviewHeight(viewportHeight: CGFloat) -> CGFloat? {
            guard usesAdaptivePhonePreviews, viewportHeight.isFinite, flatResultsPanelHeight > 0,
                  collapsedResultsSize.height > 0, phoneCollapsedResultsHeaderHeight > 0
            else { return nil }
            let fixedHeight = flatResultsPanelHeight - collapsedResultsSize.height
                + phoneCollapsedResultsHeaderHeight + Self.collapsedResultsVerticalPadding * 2
            return max(0, viewportHeight - fixedHeight)
        }
    #endif

    #if os(macOS)
        func collapsedPreviewLineLimits(
            for runs: [HomeViewModel.ModelRunViewState],
            previews: [String: AttributedString],
            viewportHeight: CGFloat
        ) -> [String: Int] {
            let font = NSFont.systemFont(ofSize: Self.collapsedPreviewFontSize)
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            let textWidth = collapsedResultsSize.width - collapsedPreviewLabelWidth(for: runs)
                - Self.collapsedPreviewColumnSpacing
            guard textWidth > 0, lineHeight > 0, flatResultsPanelHeight > 0, collapsedResultsSize.height > 0 else {
                return [:]
            }

            // Everything in the panel except the collapsed block keeps its height whatever the line limits are.
            let fixedHeight = flatResultsPanelHeight - collapsedResultsSize.height
            let blockChromeHeight = Self.collapsedResultsVerticalPadding * 2 + lineHeight
                + Self.collapsedResultsRowSpacing * CGFloat(runs.count)
            let previewHeight = viewportHeight - fixedHeight - blockChromeHeight
            let lineBudget = previewHeight.isFinite ? Int((previewHeight / lineHeight).rounded(.down)) : 0

            let neededLines = runs.map { run in
                let text = String((previews[run.id] ?? AttributedString()).characters) as NSString
                let height = text.boundingRect(
                    with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font]
                ).height
                return max(1, Int((height / lineHeight).rounded(.up)))
            }
            let limits = HomeTextLayoutPolicy.collapsedPreviewLineLimits(
                neededLines: neededLines,
                lineBudget: lineBudget
            )
            return Dictionary(zip(runs.map(\.id), limits)) { first, _ in first }
        }
    #endif

    func performInputActionIfPossible() {
        guard viewModel.canSend else { return }
        hideKeyboard()
        viewModel.performSelectedAction()
    }

    var actionChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                actionChipsStack { actionID in
                    scrollActionChip(actionID, proxy: proxy)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 4)
            }
            // Bleed past the container's 20pt padding to the screen edge on iPhone,
            // while resting content stays aligned with the rows above and below.
            .contentMargins(.horizontal, actionChipsEdgeBleed, for: .scrollContent)
            .padding(.horizontal, -actionChipsEdgeBleed)
            .mask {
                // Fade at the trailing screen edge so cut-off chips read as scrollable.
                if actionChipsEdgeBleed > 0 {
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: actionChipsEdgeBleed * 2)
                    }
                } else {
                    Color.black
                }
            }
            .onChange(of: viewModel.selectedActionID) { _, actionID in
                scrollActionChip(actionID, proxy: proxy)
            }
        }
    }

    /// Wide layouts center a width-limited column, so bleeding there would overshoot it.
    var actionChipsEdgeBleed: CGFloat {
        #if os(iOS)
            horizontalSizeClass == .compact ? 20 : 0
        #else
            0
        #endif
    }

    func actionChipsStack(onActionSelected: @escaping (ActionConfig.ID) -> Void) -> some View {
        HStack(spacing: TLingoSpacing.sm) {
            ForEach(viewModel.actions) { action in
                let isSelected = action.id == viewModel.selectedAction?.id

                Button {
                    onActionSelected(action.id)
                    if viewModel.selectAction(action) {
                        if viewModel.requiresAIModelSelection(for: action) {
                            showAIModelRequiredAlert = true
                        } else {
                            viewModel.performSelectedAction()
                        }
                    }
                } label: {
                    Text(action.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? colors.chipPrimaryText : colors.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, TLingoSpacing.md)
                        .padding(.vertical, 10)
                        .background {
                            Capsule(style: .continuous)
                                .fill(
                                    isSelected
                                        ? colors.chipPrimaryBackground
                                        : (
                                            colorScheme == .dark
                                                ? colors.chipSecondaryBackground.opacity(0.72)
                                                : colors.cardBackground.opacity(0.78)
                                        )
                                )
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .id(action.id)
            }

            if let onManageActionsTap, showsManageActionsButton {
                manageActionsButton(action: onManageActionsTap)
            }
        }
    }

    func scrollActionChip(_ actionID: ActionConfig.ID?, proxy: ScrollViewProxy) {
        guard let actionID else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(actionID, anchor: .center)
        }
    }

    func manageActionsButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(colors.textPrimary)
                .frame(width: 40, height: 40)
                .background {
                    Circle()
                        .fill(
                            colorScheme == .dark
                                ? colors.chipSecondaryBackground.opacity(0.72)
                                : colors.cardBackground.opacity(0.78)
                        )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Manage Actions")
        .accessibilityIdentifier("home_manage_actions_button")
    }

    var hintLabel: some View {
        Text(viewModel.placeholderHint)
            .font(.system(size: 14))
            .foregroundColor(colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }

    var providerResultCardBackground: some View {
        RoundedRectangle(cornerRadius: TLingoRadius.medium, style: .continuous)
            .fill(colors.cardBackground)
    }

    var providerResultsSection: some View {
        VStack(spacing: 16) {
            ForEach(viewModel.displayedModelRuns) { run in
                providerResultCard(for: run)
            }

            if shouldShowInlineSatisfactionPrompt {
                satisfactionPromptResultCell
            }
        }
    }

    @ViewBuilder
    func providerResultCard(for run: HomeViewModel.ModelRunViewState) -> some View {
        let runID = run.id
        let cardContent = VStack(alignment: .leading, spacing: 12) {
            content(for: run)

            // Bottom info bar
            bottomInfoBar(for: run)
        }
        .padding(16)

        #if os(iOS)
            cardContent
                .background(providerResultCardBackground)
            #if DEBUG
                .background(TranslationFrameProbe(run: run))
            #endif
                .modifier(ResultDetailInteraction(isEnabled: isSuccessfulRun(run)) {
                    presentResultDetail(runID: runID)
                })
        #else
            cardContent
                .background(providerResultCardBackground)
        #endif
    }

    func isSuccessfulRun(_ run: HomeViewModel.ModelRunViewState) -> Bool {
        if case .success = run.status {
            return true
        }
        return false
    }

    #if os(iOS)
        struct SelectedResult: Identifiable {
            let id: String
        }

        func presentResultDetail(runID: String) {
            resultDetailDetent = .medium
            selectedResult = SelectedResult(id: runID)
        }

        func resultDetailSheet(for runID: String) -> some View {
            NavigationStack {
                if let run = viewModel.modelRuns.first(where: { $0.id == runID }),
                   case let .success(result) = run.status
                {
                    TranslationResultDetailView(
                        sourceText: resultDetailSourceText,
                        actionName: viewModel.selectedAction?.displayName,
                        actionIcon: viewModel.selectedAction?.outputType.systemImageName,
                        modelDisplayName: run.modelDisplayName,
                        durationText: run.durationText,
                        result: result
                    )
                } else {
                    Text("Result unavailable")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(colors.textSecondary)
                        .navigationTitle("Result")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(.visible, for: .navigationBar)
                }
            }
        }

        var resultDetailSourceText: String {
            let requestText = viewModel.currentRequestInputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !requestText.isEmpty {
                return viewModel.currentRequestInputText
            }
            return viewModel.inputText
        }
    #endif

    @ViewBuilder
    func bottomInfoBar(
        for run: HomeViewModel.ModelRunViewState
    ) -> some View {
        let runID = run.id

        switch run.status {
        case .idle, .running:
            EmptyView()

        case let .streaming(_, start):
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(colors.accent)
                Text(run.modelDisplayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(colors.textSecondary)
                AnimatedEllipsis()
                    .font(.system(size: 13))
                    .foregroundColor(colors.textSecondary)
                Spacer()
                liveTimer(start: start)
            }

        case let .streamingSentencePairs(_, start):
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(colors.accent)
                Text(run.modelDisplayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(colors.textSecondary)
                AnimatedEllipsis()
                    .font(.system(size: 13))
                    .foregroundColor(colors.textSecondary)
                Spacer()
                liveTimer(start: start)
            }

        case let .success(result):
            HStack(spacing: 12) {
                // Status + Duration + Model Name + Info
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(colors.success)
                        .font(.system(size: 14))

                    if let duration = run.durationText {
                        Text(duration)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(colors.textSecondary)
                    }

                    Text(run.modelDisplayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(colors.textSecondary)

                    providerInfoButton(runID: runID)
                }

                Spacer()

                // Action buttons (only show here when no supplementalTexts, i.e., plain text mode)
                if result.sentencePairs.isEmpty && result.supplementalTexts.isEmpty {
                    actionButtons(copyText: result.copyText, runID: runID)
                }
            }

        case .failure:
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: run.status.isUnsupported ? "nosign" : "exclamationmark.triangle.fill")
                        .foregroundColor(run.status.isUnsupported ? colors.textPrimary : colors.error)
                        .font(.system(size: 14))

                    if let duration = run.durationText {
                        Text(duration)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(colors.textSecondary)
                    }

                    Text(run.modelDisplayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(colors.textSecondary)

                    providerInfoButton(runID: runID)
                }

                Spacer()

                // Retry button (retry only this run)
                if !run.status.isUnsupported {
                    retryButton(runID: runID)
                }
            }
        }
    }

    /// Retries one run, or asks for the Apple Translate language download when that is what failed.
    func retryButton(runID: String) -> some View {
        let downloadsLanguage = runID == ModelConfig.appleTranslateID && viewModel.appleTranslateNeedsLanguageDownload
        return Button {
            if downloadsLanguage {
                viewModel.downloadAppleTranslateLanguage(runID: runID)
            } else {
                viewModel.retryRun(runID: runID)
            }
        } label: {
            Group {
                if downloadsLanguage {
                    Label("Download", systemImage: "arrow.down.circle")
                } else {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(colors.accent)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func actionButtons(copyText: String, runID: String, showsChat: Bool = true) -> some View {
        // Full action buttons for bottom bar (plain text mode)
        diffToggleButton(for: runID)
        compactCopyButton(for: copyText)
        if let draft = viewModel.vocabularyDraft(forRunID: runID) {
            VocabularySaveButton(draft: draft, iconSize: 14)
        }
        if showsChat {
            chatButton(for: runID)
        }
        #if os(macOS)
            if let onResultReplace {
                Button {
                    copyToPasteboard(copyText)
                    onResultReplace(copyText)
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14))
                        .foregroundColor(colors.textPrimary)
                }
                .buttonStyle(.plain)
                .help("Replace")
                .accessibilityLabel("Replace")
            }
        #elseif os(iOS)
            if let context, context.allowsReplacement {
                Button {
                    copyToPasteboard(copyText)
                    context.finish(translation: AttributedString(copyText))
                } label: {
                    Label("Replace", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(colors.accent)
            }
        #endif
    }

    @ViewBuilder
    func diffToggleButton(for runID: String) -> some View {
        if viewModel.hasDiff(for: runID) {
            let isShowingDiff = viewModel.isDiffShown(for: runID)
            Button {
                viewModel.toggleDiffDisplay(for: runID)
            } label: {
                Image(systemName: isShowingDiff ? "eye.slash" : "eye")
                    .font(.system(size: 14))
                    .foregroundColor(isShowingDiff ? colors.accent : colors.textPrimary)
            }
            .buttonStyle(.plain)
            .help(isShowingDiff ? "Hide changes" : "Show changes")
        }
    }

    func providerInfoButton(runID: String) -> some View {
        Button {
            if DeveloperMode.isEnabled {
                // Developer mode: jump straight to the recorded request details
                // (provider meta is still available via logs).
                viewModel.presentDebugRequestDetails(for: runID)
            } else {
                showingProviderInfo = showingProviderInfo == runID ? nil : runID
            }
        } label: {
            Image(systemName: DeveloperMode.isEnabled ? "exclamationmark.circle" : "info.circle")
                .font(.system(size: 14))
                .foregroundColor(colors.textPrimary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: providerInfoBinding(for: runID)) {
            if let run = viewModel.modelRuns.first(where: { $0.id == runID }) {
                providerInfoPopover(for: run)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    func providerInfoBinding(for runID: String) -> Binding<Bool> {
        Binding(
            get: { showingProviderInfo == runID },
            set: { isPresented in
                if !isPresented, showingProviderInfo == runID {
                    showingProviderInfo = nil
                }
            }
        )
    }

    func providerInfoPopover(for run: HomeViewModel.ModelRunViewState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(run.modelDisplayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(colors.textPrimary)
            if let duration = run.durationText {
                Text(
                    String(
                        format: NSLocalizedString("Duration: %@", comment: "Provider run duration"),
                        duration
                    )
                )
                .font(.system(size: 12))
                .foregroundColor(colors.textSecondary)
            }
            if let breakdown = run.status.latencyBreakdown {
                Divider()
                HStack(spacing: 4) {
                    Text("Client → Azure:")
                        .font(.system(size: 11))
                        .foregroundColor(colors.textSecondary)
                    Text(breakdown.clientToAzureText)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(colors.textPrimary)
                }
                HStack(spacing: 4) {
                    Text("Azure → Model:")
                        .font(.system(size: 11))
                        .foregroundColor(colors.textSecondary)
                    Text(breakdown.upstreamText)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(colors.textPrimary)
                }
            }
        }
        .fixedSize()
        .padding(12)
    }

    func liveTimer(start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 1.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Text(String(format: "%.0fs", elapsed))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(colors.textSecondary)
        }
    }

    func skeletonPlaceholder() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0 ..< 3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(colors.skeleton)
                    .frame(height: 10)
                    .frame(maxWidth: index == 2 ? 180 : .infinity)
                    .shimmer()
            }
        }
    }

    func compactCopyButton(for text: String) -> some View {
        Button {
            copyToPasteboard(text)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 14))
                .foregroundColor(colors.textPrimary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func chatButton(for runID: String) -> some View {
        if let run = viewModel.modelRuns.first(where: { $0.id == runID }),
           !run.model.isDirectTranslation
        {
            Button {
                if let session = viewModel.createConversation(from: run) {
                    presentConversation(session)
                }
            } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: 14))
                    .foregroundColor(colors.textPrimary)
            }
            .buttonStyle(.plain)
            .help("Continue conversation")
            .accessibilityIdentifier("chat_button")
        }
    }

    func suggestedActionChips(actions: [String], runID: String) -> some View {
        SuggestedActionChips(actions: actions) { action in
            if let run = viewModel.modelRuns.first(where: { $0.id == runID }),
               let session = viewModel.createConversationWithFollowUp(from: run, followUp: action)
            {
                presentConversation(session)
            }
        }
    }

    @ViewBuilder
    func content(
        for run: HomeViewModel.ModelRunViewState,
        textPreset: MarkdownContentPreset = .compact,
        showsInlineActions: Bool = true,
        animatesStreamingText: Bool = true
    ) -> some View {
        let pairs: [SentencePair] = switch run.status {
        case let .streamingSentencePairs(pairs, _): pairs
        case let .success(result): result.sentencePairs
        default: []
        }
        if pairs.isEmpty {
            nonPairContent(
                for: run,
                textPreset: textPreset,
                showsInlineActions: showsInlineActions,
                animatesStreamingText: animatesStreamingText
            )
        } else {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pairs.indices, id: \.self) { index in
                        let pair = pairs[index]
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pair.original)
                                .font(fontLibrary.style.font(size: 14))
                                .foregroundColor(colors.textSecondary)
                                .textSelection(.enabled)
                            Text(pair.translation)
                                .font(fontLibrary.style.font(size: 14))
                                .foregroundColor(colors.textPrimary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 8)
                        .transition(.opacity)

                        if index < pairs.count - 1 {
                            Divider()
                        }
                    }
                }
                .animation(isRunLoading(run) ? .easeOut(duration: 0.2) : nil, value: pairs.count)

                if case let .success(result) = run.status {
                    resultAdditions(result, run: run, showsInlineActions: false)
                }
            }
        }
    }

    @ViewBuilder
    private func nonPairContent(
        for run: HomeViewModel.ModelRunViewState,
        textPreset: MarkdownContentPreset,
        showsInlineActions: Bool,
        animatesStreamingText: Bool
    ) -> some View {
        switch run.status {
        case .idle, .running, .streamingSentencePairs:
            skeletonPlaceholder()

        case let .streaming(text, _):
            if text.isEmpty {
                skeletonPlaceholder()
            } else {
                StreamedMarkdownView(
                    source: run.markdownStreamSource,
                    config: MarkdownTypography.renderConfig(
                        preset: .compact,
                        textColor: colors.textPrimary,
                        secondaryTextColor: colors.textSecondary,
                        accentColor: colors.accent,
                        animatesText: animatesStreamingText,
                        readingStyle: fontLibrary.style
                    )
                )
                .id(fontLibrary.style)
                .contentDirectionAware(text)
            }

        case let .success(result):
            VStack(alignment: .leading, spacing: 12) {
                if let diff = result.diff, run.showDiff {
                    StyledDiffView(diff: diff)
                } else {
                    let mainText = !result.supplementalTexts.isEmpty ? result.copyText : result.text
                    MarkdownContentView(text: mainText, preset: textPreset, timingTrace: run.timingTrace)
                }

                resultAdditions(result, run: run, showsInlineActions: showsInlineActions)
            }

        case let .failure(message, _, _, isUnsupported):
            VStack(alignment: .leading, spacing: 10) {
                Text(isUnsupported ? String(localized: "Not Supported") : String(localized: "Request Failed"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isUnsupported ? colors.textSecondary : colors.error)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(colors.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func resultAdditions(
        _ result: HomeViewModel.ModelRunViewState.SuccessResult,
        run: HomeViewModel.ModelRunViewState,
        showsInlineActions: Bool
    ) -> some View {
        if !result.suggestedActions.isEmpty, !showsOnlyResults || onResultConversation != nil {
            suggestedActionChips(actions: result.suggestedActions, runID: run.id)
        }

        if showsInlineActions, !result.supplementalTexts.isEmpty {
            HStack(spacing: 12) {
                Spacer()
                actionButtons(copyText: result.copyText, runID: run.id)
            }
        }

        if !result.supplementalTexts.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(result.supplementalTexts.enumerated()), id: \.offset) { entry in
                    CompactMarkdownContent(text: entry.element, timingTrace: run.timingTrace)
                }
            }
        }
    }

    func copyToPasteboard(_ text: String) {
        PasteboardHelper.copy(text)
    }

    @MainActor
    func applyPastedTextIfNeeded(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        viewModel.inputText = text
        isInputExpanded = true
        viewModel.performSelectedAction()
    }
}

struct CollapsedStreamingPreviewText: View {
    @ObservedObject var preview: HomeViewModel.ModelRunStreamPreview
    let fallback: String

    var body: some View {
        Text(preview.text.isEmpty ? fallback : preview.text)
    }
}

#if os(iOS)
    private struct ResultDetailInteraction: ViewModifier {
        let isEnabled: Bool
        let open: () -> Void

        func body(content: Content) -> some View {
            content
                .contentShape(Rectangle())
                .gesture(TapGesture().onEnded { open() }, including: isEnabled ? .gesture : .subviews)
                .accessibilityAddTraits(isEnabled ? .isButton : [])
                .accessibilityActions {
                    if isEnabled {
                        Button("Open Result", action: open)
                    }
                }
        }
    }

    private struct PhoneCollapsedPreviewLayout: Layout {
        let height: CGFloat
        let spacing: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
            let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            let heights = rowHeights(width: width, subviews: subviews)
            return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
        }

        func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
            let heights = rowHeights(width: bounds.width, subviews: subviews)
            var rowTop = bounds.minY
            for (subview, rowHeight) in zip(subviews, heights) {
                subview.place(
                    at: CGPoint(x: bounds.minX, y: rowTop),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: rowHeight)
                )
                rowTop += rowHeight + spacing
            }
        }

        private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
            func measuredHeight(_ index: Int, at height: CGFloat?) -> CGFloat {
                subviews[index].sizeThatFits(ProposedViewSize(width: width, height: height)).height
            }
            let fullHeights = subviews.indices.map { measuredHeight($0, at: nil) }
            var heights = subviews.indices.map { measuredHeight($0, at: 0) }
            var remaining = height - spacing * CGFloat(max(0, subviews.count - 1)) - heights.reduce(0, +)
            let order = subviews.indices.sorted { fullHeights[$0] - heights[$0] < fullHeights[$1] - heights[$1] }
            for (position, index) in order.enumerated() where remaining > 0 {
                let share = remaining / CGFloat(order.count - position)
                let measured = measuredHeight(index, at: heights[index] + share)
                remaining -= measured - heights[index]
                heights[index] = measured
            }
            for index in order.sorted(by: { heights[$0] < heights[$1] }) where remaining > 0 {
                guard heights[index] < fullHeights[index] else { continue }
                let measured = measuredHeight(index, at: heights[index] + remaining)
                remaining -= measured - heights[index]
                heights[index] = measured
            }
            return heights
        }
    }
#endif
