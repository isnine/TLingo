//
//  LanguageSwitcherView.swift
//  ShareCore
//

import SwiftUI

public enum LanguagePreferenceScope {
    case text
    case realtime
}

/// A language selector that adapts to the current action prompt's placeholders:
/// - Both languages (`{{sourceLanguage}}` + `{{targetLanguage}}`): `[Auto ▾]  →  [日本語 ▾]`
/// - Only one language: `Target:  [日本語 ▾]` (labeled single control, no arrow)
/// - App language (`{appLanguage}`): a static explanation-language caption, no controls
/// - No language placeholders: a static "language chosen by AI" caption, no controls
public struct LanguageSwitcherView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var preferences = AppPreferences.shared

    @State private var isTargetPickerPresented = false
    @State private var isSourcePickerPresented = false
    @State private var targetCode: String = ""
    @State private var sourceCode: String = ""

    let globeFont: Font
    let textFont: Font
    let chevronFont: Font
    let foregroundColor: Color?
    let showsControlBackgrounds: Bool
    let sourceOptions: [SourceLanguageOption]
    let targetOptions: [TargetLanguageOption]
    let disabledSourceOptions: Set<SourceLanguageOption>
    let preferenceScope: LanguagePreferenceScope
    let sourceFallbackTitle: String?
    let targetFallbackTitle: String?
    let isSourceSelectionDisabled: Bool
    let isTargetSelectionDisabled: Bool
    let isSwapDisabled: Bool
    /// Language placeholders used by the current action prompt.
    let languageDependencies: PromptLanguageDependencies
    /// When non-nil, target language was auto-corrected to this value.
    let resolvedTarget: TargetLanguageOption?
    /// Called when the user picks an override target from the resolved-target menu.
    let onOverrideTarget: ((TargetLanguageOption) -> Void)?
    /// When non-nil, shows the source selector with a strikethrough and this detected language label beside it.
    let detectedSource: SourceLanguageOption?
    /// Called when the user picks a new source language (so callers can clear detectedSource state).
    let onSourceChanged: (() -> Void)?
    /// Called once after any source/target selection or swap changes.
    let onSelectionChanged: (() -> Void)?

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    public init(
        globeFont: Font = .system(size: 12),
        textFont: Font = .system(size: 13, weight: .medium),
        chevronFont: Font = .system(size: 8),
        foregroundColor: Color? = nil,
        showsControlBackgrounds: Bool = true,
        sourceOptions: [SourceLanguageOption] = SourceLanguageOption.allCases,
        targetOptions: [TargetLanguageOption] = TargetLanguageOption.selectionOptions,
        disabledSourceOptions: Set<SourceLanguageOption> = [],
        preferenceScope: LanguagePreferenceScope = .text,
        sourceFallbackTitle: String? = nil,
        targetFallbackTitle: String? = nil,
        isSourceSelectionDisabled: Bool = false,
        isTargetSelectionDisabled: Bool = false,
        isSwapDisabled: Bool = false,
        languageDependencies: PromptLanguageDependencies = .none,
        resolvedTarget: TargetLanguageOption? = nil,
        onOverrideTarget: ((TargetLanguageOption) -> Void)? = nil,
        detectedSource: SourceLanguageOption? = nil,
        onSourceChanged: (() -> Void)? = nil,
        onSelectionChanged: (() -> Void)? = nil
    ) {
        self.globeFont = globeFont
        self.textFont = textFont
        self.chevronFont = chevronFont
        self.foregroundColor = foregroundColor
        self.showsControlBackgrounds = showsControlBackgrounds
        self.sourceOptions = sourceOptions
        self.targetOptions = targetOptions
        self.disabledSourceOptions = disabledSourceOptions
        self.preferenceScope = preferenceScope
        self.sourceFallbackTitle = sourceFallbackTitle
        self.targetFallbackTitle = targetFallbackTitle
        self.isSourceSelectionDisabled = isSourceSelectionDisabled
        self.isTargetSelectionDisabled = isTargetSelectionDisabled
        self.isSwapDisabled = isSwapDisabled
        self.languageDependencies = languageDependencies
        self.resolvedTarget = resolvedTarget
        self.onOverrideTarget = onOverrideTarget
        self.detectedSource = detectedSource
        self.onSourceChanged = onSourceChanged
        self.onSelectionChanged = onSelectionChanged
    }

    private var resolvedColor: Color {
        foregroundColor ?? colors.textSecondary
    }

    private var usesCompactMetrics: Bool {
        globeFont == .system(size: 10)
    }

    private var chipHorizontalPadding: CGFloat {
        usesCompactMetrics ? 8 : 10
    }

    /// Fixed control height so the chip does not resize when switching actions/languages.
    private var chipHeight: CGFloat {
        usesCompactMetrics ? 28 : 34
    }

    /// Minimum chip width so short language names stay centered instead of hugging the text.
    private var chipMinWidth: CGFloat {
        #if os(macOS)
            return usesCompactMetrics ? 60 : 68
        #else
            return usesCompactMetrics ? 72 : 96
        #endif
    }

    private var languageChipMaxWidth: CGFloat {
        usesCompactMetrics ? 116 : 156
    }

    private var glassChipTint: Color {
        colors.cardBackground.opacity(colorScheme == .dark ? 0.10 : 0.14)
    }

    private var glassChipFallbackTint: Color {
        colors.chipSecondaryBackground.opacity(0.65)
    }

    private var directionalIconWidth: CGFloat {
        usesCompactMetrics ? 30 : 38
    }

    private var targetDisplayName: String {
        let target = selectedTargetLanguage
        guard targetOptions.contains(target) else {
            return targetFallbackTitle ?? target.primaryLabel
        }
        if target == .appLanguage {
            return TargetLanguageOption.systemLanguageDisplayName()
        }
        return target.primaryLabel
    }

    private var targetResolvedOriginalDisplayName: String {
        selectedTargetLanguage == .appLanguage ? String(localized: "System") : targetDisplayName
    }

    private var sourceDisplayName: String {
        let source = selectedSourceLanguage
        guard sourceOptions.contains(source) else {
            return sourceFallbackTitle ?? source.primaryLabel
        }
        return source.primaryLabel
    }

    private var sourceRows: [LanguageRow] {
        sourceOptions.map {
            LanguageRow(
                id: $0.rawValue,
                primaryLabel: $0.primaryLabel,
                secondaryLabel: $0.secondaryLabel,
                isDisabled: disabledSourceOptions.contains($0),
                disabledReason: disabledSourceOptions.contains($0) ?
                    String(localized: "Not supported by selected recognition model") :
                    nil
            )
        }
    }

    private var canSwapSelectedLanguages: Bool {
        guard sourceOptions.contains(selectedSourceLanguage),
              targetOptions.contains(selectedTargetLanguage)
        else {
            return false
        }
        let swapped = LanguageDirectionSwap.swapped(source: selectedSourceLanguage, target: selectedTargetLanguage)
        return isSourceOptionEnabled(swapped.source)
    }

    private var isSwapButtonDisabled: Bool {
        isSwapDisabled || !canSwapSelectedLanguages
    }

    // MARK: - Layout selection

    private enum LayoutMode {
        case both
        case sourceOnly
        case targetOnly
        case appLanguage
        case auto
    }

    private var layoutMode: LayoutMode {
        switch (languageDependencies.usesSourceLanguage, languageDependencies.usesTargetLanguage) {
        case (true, true):
            return .both
        case (true, false):
            return .sourceOnly
        case (false, true):
            return .targetOnly
        case (false, false):
            return languageDependencies.usesAppLanguage ? .appLanguage : .auto
        }
    }

    @ViewBuilder
    private var layoutContent: some View {
        HStack(spacing: 6) {
            switch layoutMode {
            case .both:
                directionalLayout
            case .sourceOnly:
                sectionLabel(String(localized: "Source language:"))
                sourceButton
            case .targetOnly:
                sectionLabel(String(localized: "Target language:"), foregroundColor: colors.accent)
                targetSection
            case .appLanguage:
                appLanguageLabel
            case .auto:
                autoDetectLabel
            }
        }
    }

    public var body: some View {
        glassLayoutContent
            .sheet(isPresented: $isTargetPickerPresented) {
                LanguagePickerView(
                    selectedCode: $targetCode,
                    isPresented: $isTargetPickerPresented,
                    availableOptions: targetOptions,
                    title: String(localized: "Select Target Language")
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isSourcePickerPresented) {
                LanguagePickerView(
                    selectedCode: $sourceCode,
                    isPresented: $isSourcePickerPresented,
                    rows: sourceRows,
                    title: String(localized: "Select Source Language")
                )
                .presentationDetents([.medium, .large])
            }
            .onChange(of: targetCode) {
                if let option = TargetLanguageOption(rawValue: targetCode), targetOptions.contains(option) {
                    let didChange = option != selectedTargetLanguage
                    setTargetLanguage(option, reason: "LanguageSwitcher target picker")
                    if didChange {
                        onSelectionChanged?()
                    }
                }
            }
            .onChange(of: sourceCode) {
                if let option = SourceLanguageOption(rawValue: sourceCode), isSourceOptionEnabled(option) {
                    let didChange = option != selectedSourceLanguage
                    setSourceLanguage(option, reason: "LanguageSwitcher source picker")
                    if didChange {
                        onSourceChanged?()
                        onSelectionChanged?()
                    }
                }
            }
    }

    @ViewBuilder
    private var glassLayoutContent: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) {
                layoutContent
            }
        } else {
            layoutContent
        }
    }

    // MARK: - Auto-detect caption (no language placeholders)

    private var appLanguageLabel: some View {
        Text(String(localized: "Explanation language follows app language"))
            .font(textFont)
            .foregroundColor(resolvedColor.opacity(0.7))
            .lineLimit(1)
            .frame(height: chipHeight)
    }

    private var autoDetectLabel: some View {
        Text(String(localized: "Language chosen by AI"))
            .font(textFont)
            .foregroundColor(resolvedColor.opacity(0.7))
            .lineLimit(1)
            .frame(height: chipHeight)
    }

    // MARK: - Section label for single-language layouts

    private func baseLabel(_ text: String, foregroundColor: Color? = nil) -> some View {
        Text(text)
            .font(textFont)
            .foregroundColor(foregroundColor ?? resolvedColor)
            .lineLimit(1)
    }

    private func sectionLabel(_ text: String, foregroundColor: Color? = nil) -> some View {
        baseLabel(text, foregroundColor: foregroundColor)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func languageLabel(_ text: String) -> some View {
        baseLabel(text)
            .truncationMode(.tail)
    }

    private var chevron: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(chevronFont)
            .foregroundColor(resolvedColor.opacity(0.6))
    }

    // MARK: - Directional layout: [Auto ▾] → [日本語 ▾]

    @ViewBuilder
    private var directionalLayout: some View {
        let content = HStack(spacing: 0) {
            sourceButton(style: .grouped)

            swapLanguagesButton

            targetSection(style: .grouped)
        }
        .padding(.horizontal, usesCompactMetrics ? 4 : 6)
        .frame(height: chipHeight)
        .fixedSize(horizontal: true, vertical: false)

        if showsControlBackgrounds {
            content
                .tlingoGlassCapsule(
                    tint: glassChipTint,
                    interactive: true,
                    fallbackTint: glassChipFallbackTint,
                    fallbackStroke: colors.divider
                )
        } else {
            content
        }
    }

    private var swapLanguagesButton: some View {
        Button {
            swapLanguages()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: usesCompactMetrics ? 12 : 16, weight: .medium))
                .foregroundColor(colors.accent)
                .frame(width: directionalIconWidth, height: chipHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSwapButtonDisabled)
        .opacity(isSwapButtonDisabled ? 0.55 : 1)
        .accessibilityLabel("Swap languages")
        .accessibilityIdentifier("language_switcher_swap_button")
    }

    private func swapLanguages() {
        guard canSwapSelectedLanguages else { return }
        let result = LanguageDirectionSwap.swapped(
            source: selectedSourceLanguage,
            target: selectedTargetLanguage
        )
        let didChangeSource = result.source != selectedSourceLanguage
        let didChangeTarget = result.target != selectedTargetLanguage
        setSourceLanguage(result.source, reason: "LanguageSwitcher swap")
        setTargetLanguage(result.target, reason: "LanguageSwitcher swap")
        if didChangeSource {
            onSourceChanged?()
        }
        if didChangeSource || didChangeTarget {
            onSelectionChanged?()
        }
    }

    // MARK: - Source control

    private enum LanguageControlStyle: Equatable {
        case standalone
        case grouped
    }

    private var sourceButton: some View {
        sourceButton(style: .standalone)
    }

    private func sourceButton(style: LanguageControlStyle) -> some View {
        Button {
            sourceCode = selectedSourceLanguage.rawValue
            isSourcePickerPresented = true
        } label: {
            languageControl(style: style) {
                HStack(spacing: 3) {
                    let showDetected = detectedSource != nil && detectedSource != selectedSourceLanguage
                    if showDetected, let detected = detectedSource {
                        languageLabel(sourceDisplayName)
                            .strikethrough(true)
                            .opacity(0.5)
                            .layoutPriority(-1)
                        languageLabel(detected.primaryLabel)
                            .layoutPriority(1)
                    } else {
                        languageLabel(sourceDisplayName)
                            .layoutPriority(1)
                    }
                    if style == .standalone {
                        chevron
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isSourceSelectionDisabled)
        .opacity(isSourceSelectionDisabled ? 0.55 : 1)
    }

    // MARK: - Target control (plain button or auto-corrected menu)

    @ViewBuilder
    private var targetSection: some View {
        targetSection(style: .standalone)
    }

    @ViewBuilder
    private func targetSection(style: LanguageControlStyle) -> some View {
        if let resolved = resolvedTarget, let onOverride = onOverrideTarget {
            targetResolvedMenu(resolved: resolved, onOverride: onOverride, style: style)
        } else {
            targetButton(style: style)
        }
    }

    private var targetButton: some View {
        targetButton(style: .standalone)
    }

    private func targetButton(style: LanguageControlStyle) -> some View {
        Button {
            targetCode = selectedTargetLanguage.rawValue
            isTargetPickerPresented = true
        } label: {
            targetChip(targetDisplayName, style: style)
        }
        .buttonStyle(.plain)
        .disabled(isTargetSelectionDisabled)
        .opacity(isTargetSelectionDisabled ? 0.55 : 1)
    }

    private func targetResolvedMenu(
        resolved: TargetLanguageOption,
        onOverride: @escaping (TargetLanguageOption) -> Void,
        style: LanguageControlStyle = .standalone
    ) -> some View {
        let showResolved = resolved != selectedTargetLanguage
        return Menu {
            ForEach(targetOptions.filter { $0 != .appLanguage && $0 != resolved }) { option in
                Button(option.primaryLabel) {
                    selectResolvedTarget(option, onOverride: onOverride)
                }
            }
        } label: {
            if showResolved {
                targetResolvedChip(resolved: resolved, style: style)
            } else {
                targetChip(targetDisplayName, style: style)
            }
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .buttonStyle(.plain)
        .disabled(isTargetSelectionDisabled)
        .opacity(isTargetSelectionDisabled ? 0.55 : 1)
    }

    private func targetChip(_ text: String, style: LanguageControlStyle = .standalone) -> some View {
        languageControl(style: style) {
            HStack(spacing: 3) {
                languageLabel(text)
                    .layoutPriority(1)
                if style == .standalone {
                    chevron
                }
            }
        }
    }

    private func targetResolvedChip(resolved: TargetLanguageOption, style: LanguageControlStyle = .standalone) -> some View {
        languageControl(style: style) {
            HStack(spacing: 3) {
                targetResolvedLabel(resolved: resolved)
                if style == .standalone {
                    chevron
                }
            }
        }
    }

    private func targetResolvedLabel(resolved: TargetLanguageOption) -> some View {
        let original = Text(targetResolvedOriginalDisplayName)
            .strikethrough(true)
            .foregroundColor(resolvedColor.opacity(0.5))
        let replacement = Text(resolved.compactCodeLabel)
            .foregroundColor(resolvedColor)
        return Text("\(original) \(replacement)")
            .font(textFont)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .truncationMode(.tail)
            .layoutPriority(1)
    }

    @ViewBuilder
    private func languageControl(
        style: LanguageControlStyle,
        @ViewBuilder content: () -> some View
    ) -> some View {
        switch style {
        case .standalone:
            glassLanguageChip(content: content)
        case .grouped:
            languageChipFrame(content: content)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func glassLanguageChip(@ViewBuilder content: () -> some View) -> some View {
        if showsControlBackgrounds {
            languageChipFrame(content: content)
                .tlingoGlassCapsule(
                    tint: glassChipTint,
                    interactive: true,
                    fallbackTint: glassChipFallbackTint,
                    fallbackStroke: colors.divider
                )
        } else {
            languageChipFrame(content: content)
        }
    }

    private func languageChipFrame(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, chipHorizontalPadding)
            .frame(minWidth: chipMinWidth, maxWidth: languageChipMaxWidth, alignment: .center)
            .frame(height: chipHeight)
            // Hug content width (clamped to [min, max]) instead of greedily
            // expanding to maxWidth when the parent offers extra space.
            .fixedSize(horizontal: true, vertical: false)
    }

    private func selectResolvedTarget(
        _ option: TargetLanguageOption,
        onOverride: @escaping (TargetLanguageOption) -> Void
    ) {
        setTargetLanguage(option, reason: "LanguageSwitcher resolved target picker")
        onOverride(option)
    }

    private var selectedTargetLanguage: TargetLanguageOption {
        switch preferenceScope {
        case .text:
            return preferences.targetLanguage
        case .realtime:
            return preferences.realtimeTargetLanguage
        }
    }

    private var selectedSourceLanguage: SourceLanguageOption {
        switch preferenceScope {
        case .text:
            return preferences.sourceLanguage
        case .realtime:
            return preferences.realtimeSourceLanguage
        }
    }

    private func setTargetLanguage(_ option: TargetLanguageOption, reason: String) {
        switch preferenceScope {
        case .text:
            preferences.setTargetLanguage(option, reason: reason)
        case .realtime:
            preferences.setRealtimeTargetLanguage(option, reason: reason)
        }
    }

    private func setSourceLanguage(_ option: SourceLanguageOption, reason: String) {
        switch preferenceScope {
        case .text:
            preferences.setSourceLanguage(option, reason: reason)
        case .realtime:
            preferences.setRealtimeSourceLanguage(option, reason: reason)
        }
    }

    private func isSourceOptionEnabled(_ option: SourceLanguageOption) -> Bool {
        sourceOptions.contains(option) && !disabledSourceOptions.contains(option)
    }
}
