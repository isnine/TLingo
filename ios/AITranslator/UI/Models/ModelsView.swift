//
//  ModelsView.swift
//  TLingo
//
//  Created by Codex on 2025/01/28.
//

import os
import ShareCore
import SwiftUI

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "ModelsView")
#if canImport(Translation)
    import Translation
#endif

struct ModelsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var entitlement = Entitlement.shared
    private let embedsInNavigationStack: Bool

    @State private var models: [ModelConfig] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var enabledModelIDs: Set<String> = []
    @State private var showPaywall = false
    @State private var showLimitBanner = false
    @State private var showHiddenFreeModels = false
    @State private var showHiddenPremiumModels = false
    @State private var showInstalledLanguages = false
    @State private var showDownloadLanguagesGuide = false
    @State private var foundationModelAlertMessage = ""
    @State private var showFoundationModelAlert = false

    init(embedsInNavigationStack: Bool = true) {
        self.embedsInNavigationStack = embedsInNavigationStack
    }

    private let freeModelLimit = ModelSelectionPolicy.freeCloudModelLimit

    private var hasReachedFreeLimit: Bool {
        guard !entitlement.isPro else { return false }
        let activeFreeCount = ModelSelectionPolicy.freeCloudModelCount(in: enabledModelIDs, availableModels: models)
        #if DEBUG
            logger
                .debug(
                    "enabled=\(enabledModelIDs.count, privacy: .public), free=\(activeFreeCount, privacy: .public)"
                )
        #endif
        return activeFreeCount >= freeModelLimit
    }

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    private var modelSections: ModelListSections {
        ModelListSections(cloudModels: models, enabledIDs: enabledModelIDs)
    }

    private var selectableModels: [ModelConfig] {
        ModelConfig.translationServices + ModelConfig.appleIntelligenceModels + models
    }

    var body: some View {
        navigationContainer
            .tint(colors.accent)
            .onAppear {
                enabledModelIDs = preferences.enabledModelIDs
                #if DEBUG
                    logger.debug("onAppear enabledModelIDs=\(self.enabledModelIDs, privacy: .public)")
                #endif
                loadModels()
                // Refresh installed languages if Apple Translate is enabled.
                if enabledModelIDs.contains(ModelConfig.appleTranslateID),
                   !SnapshotLaunchArguments.isSnapshotMode()
                {
                    refreshInstalledLanguagesInBackground()
                }
            }
            .onChange(of: preferences.enabledModelIDs) { _, newValue in
                enabledModelIDs = newValue
                #if DEBUG
                    logger.debug("onChange(preferences.enabledModelIDs) → \(newValue, privacy: .public)")
                #endif
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(context: .featureLocked)
            }
            .sheet(isPresented: $showDownloadLanguagesGuide) {
                DownloadLanguagesGuideView()
            }
            .alert("Apple Intelligence", isPresented: $showFoundationModelAlert) {
            } message: {
                Text(foundationModelAlertMessage)
            }
    }

    @ViewBuilder
    private var navigationContainer: some View {
        if embedsInNavigationStack {
            NavigationStack {
                content
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
            }
        } else {
            content
            #if os(iOS)
            .toolbar(.visible, for: .navigationBar)
            #endif
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                headerSection
                if showLimitBanner {
                    freeModelLimitBanner
                }
                modelsSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
        }
        .background(colors.background.ignoresSafeArea())
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Models")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(colors.textPrimary)
            Text("Select models to use for translation")
                .font(.system(size: 16))
                .foregroundColor(colors.textSecondary)
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Loading indicator
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.7)
                    Spacer()
                }
            }

            translationServicesSection
            foundationModelSection

            if let error = errorMessage {
                errorView(error)
            } else if models.isEmpty && !isLoading {
                emptyState
            } else {
                if !modelSections.visibleFreeModels.isEmpty || !modelSections.collapsedFreeModels.isEmpty {
                    modelGroupSection(
                        title: "FREE MODELS",
                        icon: "cpu",
                        models: modelSections.visibleFreeModels,
                        hiddenModels: modelSections.collapsedFreeModels,
                        isExpanded: $showHiddenFreeModels,
                        isPremiumSection: false
                    )
                }
                if !modelSections.visiblePremiumModels.isEmpty || !modelSections.collapsedPremiumModels.isEmpty {
                    modelGroupSection(
                        title: "PREMIUM MODELS",
                        icon: "crown.fill",
                        models: modelSections.visiblePremiumModels,
                        hiddenModels: modelSections.collapsedPremiumModels,
                        isExpanded: $showHiddenPremiumModels,
                        isPremiumSection: true
                    )
                }
            }

            infoFooter
        }
    }

    private var foundationModelSection: some View {
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "apple.intelligence")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(colors.textSecondary)
                Text("APPLE INTELLIGENCE")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(colors.textSecondary)
            }
            .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(ModelConfig.appleIntelligenceModels) { model in
                    let availability = FoundationModelService.availability(for: model)
                    let badgeTitle = model.isPrivateCloudModel
                        ? String(localized: "Private Cloud")
                        : String(localized: "On-Device")
                    SelectableModelRow(
                        model: model,
                        isSelected: enabledModelIDs.contains(model.id),
                        isDimmed: !availability.isAvailable && !enabledModelIDs.contains(model.id),
                        subtitle: FoundationModelService.availabilityDescription(for: model),
                        additionalBadges: [
                            SelectableModelRow.Badge(
                                badgeTitle,
                                color: model.isPrivateCloudModel ? .blue : .green
                            ),
                        ],
                        showsDefaultBadge: false,
                        showsPremiumCrown: false,
                        showsModelTags: false
                    ) {
                        toggleFoundationModel(model)
                    }
                }
            }
            .background(cardBackground)
        }
    }

    // MARK: - Translation Services

    private var translationServicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(colors.textSecondary)
                Text("TRANSLATION")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(colors.textSecondary)
            }
            .padding(.leading, 4)

            VStack(spacing: 0) {
                // Google Translate row
                googleTranslateRow

                // Apple Translate row (only when available)
                if AppleTranslationService.shared.isAvailable {
                    Divider()
                        .padding(.leading, 50)
                    appleTranslateRow
                }
            }
            .background(cardBackground)
        }
    }

    private var googleTranslateRow: some View {
        let model = ModelConfig.googleTranslate
        let isEnabled = enabledModelIDs.contains(model.id)

        return SelectableModelRow(
            model: model,
            isSelected: isEnabled,
            subtitle: String(localized: "Free, no API key needed"),
            additionalBadges: [SelectableModelRow.Badge(String(localized: "Free"), color: .blue)],
            showsDefaultBadge: false,
            showsPremiumCrown: false,
            showsModelTags: false
        ) {
            toggleGoogleTranslate()
        }
    }

    @ViewBuilder
    private var appleTranslateRow: some View {
        let model = ModelConfig.appleTranslate
        let isEnabled = enabledModelIDs.contains(model.id)
        let installedLangs = installedLanguageOptions

        SelectableModelRow(
            model: model,
            isSelected: isEnabled,
            subtitle: String(localized: "Private & On-Device"),
            additionalBadges: [SelectableModelRow.Badge(String(localized: "On-Device"), color: .green)],
            showsDefaultBadge: false,
            showsPremiumCrown: false,
            showsModelTags: false
        ) {
            toggleAppleTranslate()
        }

        // Installed languages summary & expandable list
        if isEnabled {
            Divider()
                .padding(.leading, 50)

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showInstalledLanguages.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showInstalledLanguages ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(colors.textSecondary.opacity(0.5))
                    Text("\(installedLangs.count) languages downloaded")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showInstalledLanguages {
                ForEach(installedLangs) { lang in
                    Divider()
                        .padding(.leading, 50)

                    HStack(spacing: 8) {
                        Text(lang.nativeName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(colors.textPrimary)
                        Text(lang.englishName)
                            .font(.system(size: 13))
                            .foregroundColor(colors.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                Divider()
                    .padding(.leading, 50)

                Button {
                    showDownloadLanguagesGuide = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 14))
                        Text("How to Download More Languages")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(colors.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggleGoogleTranslate() {
        toggleSelection(for: ModelConfig.googleTranslate)
    }

    private var installedLanguageOptions: [TargetLanguageOption] {
        let installed = preferences.appleTranslateInstalledLanguages
        guard !installed.isEmpty else { return [] }
        return TargetLanguageOption.selectionOptions
            .filter { $0 != .appLanguage && installed.contains($0.rawValue) }
    }

    private func toggleAppleTranslate() {
        toggleSelection(for: ModelConfig.appleTranslate)
    }

    private func toggleFoundationModel(_ model: ModelConfig) {
        if enabledModelIDs.contains(model.id) {
            toggleSelection(for: model)
            return
        }

        let availability = FoundationModelService.availability(for: model)
        guard availability.isAvailable else {
            foundationModelAlertMessage = availability.localizedDescription
            showFoundationModelAlert = true
            return
        }
        toggleSelection(for: model)
    }

    private func refreshInstalledLanguagesInBackground() {
        Task {
            let installed = await fetchInstalledLanguages()
            await MainActor.run {
                AppPreferences.shared.setAppleTranslateInstalledLanguages(Set(installed.map(\.rawValue)))
            }
        }
    }

    private func fetchInstalledLanguages() async -> Set<TargetLanguageOption> {
        guard AppleTranslationService.shared.isAvailable else { return [] }
        if #available(iOS 17.4, macOS 14.4, *) {
            return await AppleTranslationService.shared.refreshInstalledLanguages()
        }
        return []
    }

    // MARK: - Cloud Model Sections

    private func modelGroupSection(
        title: LocalizedStringKey,
        icon: String,
        models: [ModelConfig],
        hiddenModels: [ModelConfig] = [],
        isExpanded: Binding<Bool>,
        isPremiumSection: Bool
    ) -> some View {
        ModelSectionCard(
            title: title,
            icon: icon,
            tint: isPremiumSection ? .orange : nil,
            models: models,
            collapsedModels: hiddenModels,
            isExpanded: isExpanded,
            dividerLeadingPadding: 56,
            cornerRadius: 16
        ) { model in
            modelRow(model: model)
        } headerAccessory: {
            if isPremiumSection && !entitlement.isPro {
                Spacer()
                Button {
                    showPaywall = true
                } label: {
                    Text("Upgrade")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            LinearGradient(
                                colors: [.orange, .yellow],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func modelRow(model: ModelConfig) -> some View {
        let isEnabled = enabledModelIDs.contains(model.id)
        let isLocked = model.isPremium && !entitlement.isPro
        let isDisabledByLimit = hasReachedFreeLimit && !isEnabled && !isLocked

        return SelectableModelRow(
            model: model,
            isSelected: isEnabled,
            isLocked: isLocked,
            isDimmed: isDisabledByLimit,
            subtitle: model.id
        ) {
            #if DEBUG
                logger
                    .debug(
                        "modelRow tapped: \(model.id, privacy: .public), enabled=\(isEnabled, privacy: .public)"
                    )
            #endif
            toggleSelection(for: model)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 32))
                .foregroundColor(colors.textSecondary.opacity(0.5))
            Text("No models available")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(cardBackground)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(colors.error)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(colors.textSecondary)
                .multilineTextAlignment(.center)

            Button("Retry") {
                loadModels()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(cardBackground)
    }

    private static let privacyPolicyURL = URL(
        string: "https://www.notion.so/isnine/Privacy-Policy-6ab3eecbf72f4e14b6ed8df977a84b43"
    )!

    private var infoFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20))
                    .foregroundColor(colors.success)
                Text("Powered by Built-in Cloud - No API key required")
                    .font(.system(size: 13))
                    .foregroundColor(colors.textSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 14))
                        .foregroundColor(colors.textSecondary.opacity(0.6))
                    Text(
                        "Your translation text is sent to Microsoft Azure OpenAI Service for processing. "
                            + "Data is encrypted in transit and not stored after processing."
                    )
                    .font(.system(size: 12))
                    .foregroundColor(colors.textSecondary.opacity(0.8))
                }

                Link(destination: Self.privacyPolicyURL) {
                    HStack(spacing: 4) {
                        Text("Privacy Policy")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10))
                    }
                    .font(.system(size: 12))
                }
                .padding(.leading, 22)
            }
        }
        .padding(.top, 8)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(colors.divider, lineWidth: 1)
            )
    }

    private var freeModelLimitBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.orange)

            Text("Free users can select up to \(freeModelLimit) models")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(colors.textPrimary)

            Spacer()

            Button {
                withAnimation(.spring(duration: 0.3)) {
                    showLimitBanner = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .tlingoGlassCircle(
                        tint: colors.cardBackground.opacity(0.10),
                        interactive: true,
                        fallbackTint: colors.inputBackground.opacity(0.82),
                        fallbackStroke: colors.divider
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .tlingoGlassSurface(
            cornerRadius: 12,
            tint: Color.orange.opacity(0.10),
            fallbackTint: Color.orange.opacity(0.08),
            fallbackStroke: Color.orange.opacity(0.28)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.spring(duration: 0.3)) {
                    showLimitBanner = false
                }
            }
        }
    }

    private func toggleSelection(for model: ModelConfig) {
        Task {
            let isPro = await entitlement.refreshAndGetIsPro()
            if model.isPremium, !isPro {
                showPaywall = true
            } else {
                toggleSelection(for: model, isPro: isPro)
            }
        }
    }

    private func toggleSelection(for model: ModelConfig, isPro: Bool) {
        let oldEnabledIDs = enabledModelIDs
        let result = ModelSelectionPolicy.toggle(
            model,
            enabledIDs: enabledModelIDs,
            availableModels: selectableModels,
            isPro: isPro
        )

        switch result.reason {
        case .freeCloudModelLimitReached:
            #if DEBUG
                logger.warning("toggleSelection(\(model.id, privacy: .public)): BLOCKED by free limit")
            #endif
            withAnimation(.spring(duration: 0.3)) {
                showLimitBanner = true
            }
            return
        case .requiresPro:
            showPaywall = true
            return
        case .keptDefaultModel, nil:
            break
        }

        guard result.enabledIDs != enabledModelIDs else { return }

        #if DEBUG
            logger
                .debug(
                    "toggleSelection id=\(model.id, privacy: .public), count=\(result.enabledIDs.count, privacy: .public)"
                )
        #endif

        enabledModelIDs = result.enabledIDs
        preferences.setEnabledModelIDs(result.enabledIDs)

        let hadAppleTranslate = oldEnabledIDs.contains(ModelConfig.appleTranslateID)
        let hasAppleTranslate = result.enabledIDs.contains(ModelConfig.appleTranslateID)
        if hasAppleTranslate, !hadAppleTranslate {
            refreshInstalledLanguagesInBackground()
        } else if !hasAppleTranslate, hadAppleTranslate {
            AppPreferences.shared.setAppleTranslateInstalledLanguages([])
        }
    }

    private func loadModels() {
        errorMessage = nil

        if SnapshotLaunchArguments.isSnapshotMode(),
           SnapshotLaunchArguments.fixture() == .aiModels
        {
            models = SnapshotFixtureData.cloudModels(for: .aiModels)
            enabledModelIDs = [
                ModelConfig.appleTranslateID,
                ModelConfig.googleTranslateID,
                "gpt-5-nano",
                "deepseek-v3",
            ]
            preferences.setEnabledModelIDs(enabledModelIDs)
            preferences.setAppleTranslateInstalledLanguages(["en", "zh-Hans"])
            isLoading = false
            return
        }

        // Show cached models immediately (if any), then refresh in the background.
        if let cached = ModelsService.shared.getCachedModels(), !cached.isEmpty {
            models = cached
            isLoading = true
        } else {
            isLoading = true
        }

        Task {
            do {
                let fetchedModels = try await ModelsService.shared.fetchModels(forceRefresh: true)
                await MainActor.run {
                    models = fetchedModels
                    isLoading = false

                    if enabledModelIDs.isEmpty {
                        let defaultModels = fetchedModels.filter { $0.isDefault }
                        enabledModelIDs = Set(defaultModels.map { $0.id })
                        preferences.setEnabledModelIDs(enabledModelIDs)
                        #if DEBUG
                            logger.debug("loadModels: set defaults → \(self.enabledModelIDs, privacy: .public)")
                        #endif
                    }
                }
            } catch {
                await MainActor.run {
                    // Keep showing cached models (if any) and surface the error.
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Download Languages Guide Sheet

private struct DownloadLanguagesGuideContent {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let steps: [LocalizedStringKey]
}

private struct DownloadLanguagesGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    guide
                }
                .padding(24)
            }
            .background(colors.background.ignoresSafeArea())
            .navigationTitle("Download More Languages")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var guideContent: DownloadLanguagesGuideContent {
        #if os(iOS)
            return DownloadLanguagesGuideContent(
                icon: "iphone",
                title: "On iPhone / iPad",
                subtitle: "Go to Settings to download language packs for offline use.",
                steps: [
                    "Open the **Settings** app",
                    "Tap **Apps** → **Translate**",
                    "Tap **Languages**",
                    "Toggle on the languages you want to use offline",
                ]
            )
        #else
            return DownloadLanguagesGuideContent(
                icon: "laptopcomputer",
                title: "On Mac",
                subtitle: "Download language packs from System Settings.",
                steps: [
                    "Open **System Settings**",
                    "Click **General** → **Language & Region**",
                    "Scroll down to **Translation Languages**",
                    "Click **+** to add the languages you need",
                ]
            )
        #endif
    }

    private var guide: some View {
        let content = guideContent
        return VStack(alignment: .leading, spacing: 20) {
            guideHeader(icon: content.icon, title: content.title, subtitle: content.subtitle)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(content.steps.enumerated()), id: \.offset) { index, text in
                    guideStep(number: index + 1, text: text)
                }
            }

            openSettingsButton
        }
    }

    private var openSettingsButton: some View {
        Button {
            #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            #elseif os(macOS)
                if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings") {
                    NSWorkspace.shared.open(url)
                }
            #endif
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 14, weight: .semibold))
                Text("Open Settings")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(colors.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func guideHeader(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(colors.accent)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(colors.textSecondary)
            }
        }
    }

    private func guideStep(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(colors.accent)
                .clipShape(Circle())

            Text(text)
                .font(.system(size: 15))
                .foregroundColor(colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ModelsView()
        .preferredColorScheme(.dark)
}
