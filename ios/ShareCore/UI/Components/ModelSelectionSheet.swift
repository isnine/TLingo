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
    @State private var selectionAlertReason: ModelSelectionPolicy.Reason?
    @State private var foundationModelAlertMessage = ""
    @State private var showFoundationModelAlert = false
    @State private var showCollapsedFreeModels = false
    @State private var showCollapsedPremiumModels = false
    @State private var cloudModels: [ModelConfig]

    private let selectedModel: Binding<ModelConfig>?
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

    private var displayedTranslationServices: [ModelConfig] {
        guard selectedModel != nil else { return translationServices }
        let availableIDs = Set(cloudModels.map(\.id))
        return translationServices.filter { availableIDs.contains($0.id) }
    }

    private var displayedAppleIntelligenceModels: [ModelConfig] {
        guard selectedModel != nil else { return ModelConfig.appleIntelligenceModels }
        let availableIDs = Set(cloudModels.map(\.id))
        return ModelConfig.appleIntelligenceModels.filter { availableIDs.contains($0.id) }
    }

    private var displayedCloudModels: [ModelConfig] {
        guard selectedModel != nil else { return cloudModels }
        let builtInModelIDs = Set(
            ModelConfig.translationServices.map(\.id) + ModelConfig.appleIntelligenceModels.map(\.id)
        )
        return cloudModels.filter { !builtInModelIDs.contains($0.id) }
    }

    private var modelSections: ModelListSections {
        ModelListSections(cloudModels: displayedCloudModels, enabledIDs: enabledModelIDs)
    }

    public init(cloudModels: [ModelConfig], onRequiresPro: (() -> Void)? = nil) {
        selectedModel = nil
        self.onRequiresPro = onRequiresPro
        _cloudModels = State(initialValue: cloudModels)
        _enabledModelIDs = State(initialValue: AppPreferences.shared.enabledModelIDs)
    }

    public init(
        selectedModel: Binding<ModelConfig>,
        availableModels: [ModelConfig],
        onRequiresPro: (() -> Void)? = nil
    ) {
        self.selectedModel = selectedModel
        self.onRequiresPro = onRequiresPro
        _cloudModels = State(initialValue: availableModels)
        _enabledModelIDs = State(initialValue: [selectedModel.wrappedValue.id])
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !displayedTranslationServices.isEmpty {
                        ModelSectionCard(
                            title: "Translation",
                            icon: "globe",
                            models: displayedTranslationServices
                        ) { model in
                            modelRow(model)
                        }
                    }

                    if !displayedAppleIntelligenceModels.isEmpty {
                        appleIntelligenceSection
                    }

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
                    guard selectedModel == nil else { return }
                    enabledModelIDs = newValue
                }
                .task {
                    async let entitlementRefresh: Bool = entitlement.refreshAndGetIsPro()
                    let fetchedModels: [ModelConfig]?
                    if selectedModel == nil {
                        fetchedModels = try? await ModelsService.shared.fetchModels(forceRefresh: true)
                    } else {
                        fetchedModels = nil
                    }
                    _ = await entitlementRefresh
                    if let fetchedModels {
                        cloudModels = fetchedModels
                    }
                }
        }
        .alert("Apple Intelligence", isPresented: $showFoundationModelAlert) {} message: {
            Text(foundationModelAlertMessage)
        }
        .alert(
            "Models",
            isPresented: Binding(
                get: { selectionAlertReason != nil },
                set: {
                    if !$0 {
                        selectionAlertReason = nil
                    }
                }
            ),
            presenting: selectionAlertReason
        ) { reason in
            if reason == .requiresPro, onRequiresPro != nil {
                Button("Upgrade") {
                    selectionAlertReason = nil
                    onRequiresPro?()
                }
                Button("Cancel", role: .cancel) {
                    selectionAlertReason = nil
                }
            } else {
                Button("OK") {
                    selectionAlertReason = nil
                }
            }
        } message: { reason in
            Text(message(for: reason))
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var appleIntelligenceSection: some View {
        ModelSectionCard(
            title: "Apple Intelligence",
            icon: "apple.intelligence",
            models: displayedAppleIntelligenceModels
        ) { model in
            modelRow(model)
        }
    }

    private func modelRow(_ model: ModelConfig) -> some View {
        let isEnabled = selectedModel.map { $0.wrappedValue.id == model.id } ?? enabledModelIDs.contains(model.id)
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
            select(model)
        }
    }

    private func directModelSubtitle(for model: ModelConfig) -> String {
        if model.id == ModelConfig.appleTranslateID {
            return String(localized: "Private & On-Device")
        }
        return String(localized: "Free, no API key needed")
    }

    private func select(_ model: ModelConfig) {
        Task {
            let isPro = await entitlement.refreshAndGetIsPro()
            if let selectedModel {
                guard !model.isPremium || isPro else {
                    selectionAlertReason = .requiresPro
                    return
                }
                selectedModel.wrappedValue = model
                dismiss()
            } else {
                toggle(model, isPro: isPro)
            }
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

        selectionAlertReason = result.reason
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
