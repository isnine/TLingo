//
//  ModelSelectionSheet.swift
//  ShareCore
//

import SwiftUI

public struct ModelSelectionSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var entitlement = Entitlement.shared
    @State private var enabledModelIDs: Set<String>
    @State private var message: String?
    @State private var foundationModelAlertMessage = ""
    @State private var showFoundationModelAlert = false
    @State private var showCollapsedFreeModels = false
    @State private var showCollapsedPremiumModels = false
    @State private var cloudModels: [ModelConfig]

    private let onRequiresPro: (() -> Void)?

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    private var translationServices: [ModelConfig] {
        ModelConfig.translationServices
    }

    private var availableModels: [ModelConfig] {
        translationServices + ModelConfig.appleIntelligenceModels + cloudModels
    }

    private var modelSections: ModelListSections {
        ModelListSections(cloudModels: cloudModels, enabledIDs: enabledModelIDs)
    }

    public init(cloudModels: [ModelConfig], onRequiresPro: (() -> Void)? = nil) {
        self.onRequiresPro = onRequiresPro
        _cloudModels = State(initialValue: cloudModels)
        _enabledModelIDs = State(initialValue: AppPreferences.shared.enabledModelIDs)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    resultOrderSection

                    if let message {
                        messageBanner(message)
                    }

                    ModelSectionCard(title: "Translation", icon: "globe", models: translationServices) { model in
                        modelRow(model)
                    }

                    appleIntelligenceSection

                    if !modelSections.visibleFreeModels.isEmpty || !modelSections.collapsedFreeModels.isEmpty {
                        ModelSectionCard(
                            title: "Cloud Models",
                            icon: "cpu",
                            models: modelSections.visibleFreeModels,
                            collapsedModels: modelSections.collapsedFreeModels,
                            isExpanded: $showCollapsedFreeModels
                        ) { model in
                            modelRow(model)
                        }
                    }

                    if !modelSections.visiblePremiumModels.isEmpty || !modelSections.collapsedPremiumModels.isEmpty {
                        ModelSectionCard(
                            title: "Premium Models",
                            icon: "crown.fill",
                            models: modelSections.visiblePremiumModels,
                            collapsedModels: modelSections.collapsedPremiumModels,
                            isExpanded: $showCollapsedPremiumModels
                        ) { model in
                            modelRow(model)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .background(colors.background.ignoresSafeArea())
            .navigationTitle("Models")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .onReceive(preferences.$enabledModelIDs) { newValue in
                    enabledModelIDs = newValue
                }
                .task {
                    async let entitlementRefresh: Bool = entitlement.refreshAndGetIsPro()
                    let fetchedModels = try? await ModelsService.shared.fetchModels(forceRefresh: true)
                    _ = await entitlementRefresh
                    if let fetchedModels {
                        cloudModels = fetchedModels
                    }
                }
        }
        .alert("Apple Intelligence", isPresented: $showFoundationModelAlert) {
        } message: {
            Text(foundationModelAlertMessage)
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var resultOrderSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text("Result Order")
                    .fixedSize()
                Spacer()
                resultOrderPicker
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Result Order")
                resultOrderPicker
            }
        }
        .padding(16)
        .background(colors.cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private var resultOrderPicker: some View {
        Picker("Result Order", selection: Binding(
            get: { preferences.modelResultOrder },
            set: { preferences.setModelResultOrder($0) }
        )) {
            ForEach(ModelResultOrder.allCases, id: \.self) { order in
                Text(order.title).tag(order)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityIdentifier("modelSelection.resultOrder")
    }

    private var appleIntelligenceSection: some View {
        ModelSectionCard(
            title: "Apple Intelligence",
            icon: "apple.intelligence",
            models: ModelConfig.appleIntelligenceModels
        ) { model in
            modelRow(model)
        }
    }

    private func modelRow(_ model: ModelConfig) -> some View {
        let isEnabled = enabledModelIDs.contains(model.id)
        let isLocked = model.isPremium && !entitlement.isPro
        let foundationAvailability = FoundationModelService.availability(for: model)
        let isFoundationUnavailable = model.isFoundationModel && !foundationAvailability.isAvailable && !isEnabled

        return SelectableModelRow(
            model: model,
            isSelected: isEnabled,
            isLocked: isLocked,
            isDimmed: isFoundationUnavailable,
            subtitle: model.isFoundationModel
                ? FoundationModelService.availabilityDescription(for: model)
                : (model.isDirectTranslation ? directModelSubtitle(for: model) : model.id),
            showsModelTags: !model.isDirectTranslation && !model.isFoundationModel
        ) {
            toggle(model)
        }
    }

    private func directModelSubtitle(for model: ModelConfig) -> String {
        if model.id == ModelConfig.appleTranslateID {
            return String(localized: "Private & On-Device")
        }
        return String(localized: "Free, no API key needed")
    }

    private func toggle(_ model: ModelConfig) {
        Task {
            let isPro = await entitlement.refreshAndGetIsPro()
            toggle(model, isPro: isPro)
        }
    }

    private func toggle(_ model: ModelConfig, isPro: Bool) {
        if model.isFoundationModel,
           !enabledModelIDs.contains(model.id)
        {
            let availability = FoundationModelService.availability(for: model)
            guard availability.isAvailable else {
                foundationModelAlertMessage = availability.localizedDescription
                showFoundationModelAlert = true
                return
            }
        }

        let result = ModelSelectionPolicy.toggle(
            model,
            enabledIDs: enabledModelIDs,
            availableModels: availableModels,
            isPro: isPro
        )

        if result.enabledIDs != enabledModelIDs {
            enabledModelIDs = result.enabledIDs
            preferences.setEnabledModelIDs(result.enabledIDs)
        }

        let shouldRefreshAppleLanguages = model.id == ModelConfig.appleTranslateID
            && result.enabledIDs.contains(ModelConfig.appleTranslateID)

        if shouldRefreshAppleLanguages {
            refreshInstalledLanguagesInBackground()
        } else if model.id == ModelConfig.appleTranslateID {
            preferences.setAppleTranslateInstalledLanguages([])
        }

        if result.reason == .requiresPro, let onRequiresPro {
            message = nil
            onRequiresPro()
        } else if let reason = result.reason {
            message = message(for: reason)
        } else {
            message = nil
        }
    }

    private func message(for reason: ModelSelectionPolicy.Reason) -> String {
        switch reason {
        case .freeCloudModelLimitReached:
            return String(localized: "Free users can select up to \(ModelSelectionPolicy.freeCloudModelLimit) cloud models.")
        case .requiresPro:
            return String(localized: "Upgrade to use premium models.")
        case .keptDefaultModel:
            return String(localized: "At least one model stays selected.")
        }
    }

    private func messageBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(colors.accent)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(colors.textPrimary)
            Spacer()
        }
        .padding(12)
        .tlingoGlassSurface(
            cornerRadius: 12,
            tint: colors.accent.opacity(0.08),
            fallbackTint: colors.accent.opacity(0.06),
            fallbackStroke: colors.accent.opacity(0.20)
        )
    }

    private func refreshInstalledLanguagesInBackground() {
        Task {
            guard AppleTranslationService.shared.isAvailable else { return }
            if #available(iOS 17.4, macOS 14.4, *) {
                let installed = await AppleTranslationService.shared.refreshInstalledLanguages()
                await MainActor.run {
                    preferences.setAppleTranslateInstalledLanguages(Set(installed.map(\.rawValue)))
                }
            }
        }
    }
}
