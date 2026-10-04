//
//  ModelSelectionList.swift
//  ShareCore
//

import SwiftUI

/// Model sections shared by the Models page and the model selection sheet.
///
/// `.enabledModels` toggles `AppPreferences.enabledModelIDs` and keeps the cloud catalog fresh.
/// `.single` picks one model from a fixed list, as the conversation composer does.
public struct ModelSelectionList: View {
    public enum Mode {
        case enabledModels(initialCloudModels: [ModelConfig])
        case single(selection: Binding<ModelConfig>, availableModels: [ModelConfig], onSelected: () -> Void)
    }

    private struct AlertContent: Identifiable {
        let id = UUID()
        let title: LocalizedStringKey
        let message: String
    }

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var entitlement = Entitlement.shared

    @State private var cloudModels: [ModelConfig]
    @State private var isLoading = false
    @State private var loadErrorMessage: String?
    @State private var alert: AlertContent?
    @State private var showCollapsedFreeModels = false
    @State private var showCollapsedPremiumModels = false
    @State private var showInstalledLanguages = false
    @State private var showDownloadLanguagesGuide = false
    @State private var showModelOrder = false

    private let mode: Mode
    private let onRequiresPro: (() -> Void)?

    public init(mode: Mode, onRequiresPro: (() -> Void)? = nil) {
        self.mode = mode
        self.onRequiresPro = onRequiresPro
        switch mode {
        case let .enabledModels(initialCloudModels):
            let cached = initialCloudModels.isEmpty ? (ModelsService.shared.getCachedModels() ?? []) : initialCloudModels
            _cloudModels = State(initialValue: cached)
        case let .single(_, availableModels, _):
            _cloudModels = State(initialValue: availableModels)
        }
    }

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    private var isSingleSelection: Bool {
        if case .single = mode {
            return true
        }
        return false
    }

    private var enabledIDs: Set<String> {
        switch mode {
        case .enabledModels:
            return preferences.enabledModelIDs
        case let .single(selection, _, _):
            return [selection.wrappedValue.id]
        }
    }

    // MARK: - Displayed Models

    /// In single mode the caller's list decides which built-in models are offered.
    private func offered(_ builtIns: [ModelConfig]) -> [ModelConfig] {
        guard isSingleSelection else { return builtIns }
        let offeredIDs = Set(cloudModels.map(\.id))
        return builtIns.filter { offeredIDs.contains($0.id) }
    }

    private var translationServices: [ModelConfig] {
        offered(preferences.modelListOrder.models(in: .translation, cloudModels: cloudModels))
    }

    private var appleIntelligenceModels: [ModelConfig] {
        offered(preferences.modelListOrder.models(in: .appleIntelligence, cloudModels: cloudModels))
    }

    private var displayedCloudModels: [ModelConfig] {
        let builtInIDs = Set(ModelConfig.translationServices.map(\.id) + ModelConfig.appleIntelligenceModels.map(\.id))
        return cloudModels.filter { !builtInIDs.contains($0.id) }
    }

    private var sections: ModelListSections {
        ModelListSections(
            cloudModels: displayedCloudModels, enabledIDs: enabledIDs, order: preferences.modelListOrder
        )
    }

    private var selectableModels: [ModelConfig] {
        ModelConfig.translationServices + ModelConfig.appleIntelligenceModels + displayedCloudModels
    }

    private var hasReachedFreeLimit: Bool {
        guard !isSingleSelection, !entitlement.isPro else { return false }
        return ModelSelectionPolicy.freeCloudModelCount(in: enabledIDs, availableModels: displayedCloudModels)
            >= ModelSelectionPolicy.freeCloudModelLimit
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !isSingleSelection {
                HStack {
                    Spacer()
                    Button {
                        showModelOrder = true
                    } label: {
                        Label("Reorder", systemImage: "arrow.up.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("models.reorder")
                }
            }

            ForEach(preferences.modelListOrder.orderedSections) { section in
                modelSection(section)
            }

            if displayedCloudModels.isEmpty {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else if let loadErrorMessage {
                    loadErrorView(loadErrorMessage)
                }
            }
        }
        .onAppear {
            if !isSingleSelection, enabledIDs.contains(ModelConfig.appleTranslateID) {
                refreshInstalledLanguages()
            }
        }
        .task {
            await loadCloudModels()
        }
        .alert(
            alert?.title ?? "",
            isPresented: Binding(
                get: { alert != nil },
                set: {
                    if !$0 {
                        alert = nil
                    }
                }
            ),
            presenting: alert
        ) { _ in
            Button("OK") {}
        } message: { content in
            Text(content.message)
        }
        .sheet(isPresented: $showModelOrder) {
            ModelListOrderSheet(cloudModels: cloudModels)
        }
        .sheet(isPresented: $showDownloadLanguagesGuide) {
            DownloadLanguagesGuideView()
        }
    }

    @ViewBuilder
    private func modelSection(_ section: ModelListSection) -> some View {
        switch section {
        case .translation:
            if !translationServices.isEmpty {
                sectionCard(title: section.title, icon: section.icon, models: translationServices)
            }
        case .appleIntelligence:
            if !appleIntelligenceModels.isEmpty {
                sectionCard(title: section.title, icon: section.icon, models: appleIntelligenceModels)
            }
        case .free:
            if !sections.visibleFreeModels.isEmpty || !sections.collapsedFreeModels.isEmpty {
                sectionCard(
                    title: section.title,
                    icon: section.icon,
                    models: sections.visibleFreeModels,
                    collapsedModels: sections.collapsedFreeModels,
                    isExpanded: $showCollapsedFreeModels
                )
            }
        case .premium:
            if !sections.visiblePremiumModels.isEmpty || !sections.collapsedPremiumModels.isEmpty {
                ModelSectionCard(
                    title: section.title,
                    icon: section.icon,
                    tint: .orange,
                    models: sections.visiblePremiumModels,
                    collapsedModels: sections.collapsedPremiumModels,
                    isExpanded: $showCollapsedPremiumModels,
                    dividerLeadingPadding: Self.dividerLeadingPadding,
                    cornerRadius: Self.cornerRadius
                ) { model in
                    row(for: model)
                } headerAccessory: {
                    if !entitlement.isPro, onRequiresPro != nil {
                        Spacer()
                        upgradeButton
                    }
                }
            }
        }
    }

    private static let dividerLeadingPadding: CGFloat = 52
    private static let cornerRadius: CGFloat = 16

    private func sectionCard(
        title: LocalizedStringKey,
        icon: String,
        models: [ModelConfig],
        collapsedModels: [ModelConfig] = [],
        isExpanded: Binding<Bool>? = nil
    ) -> some View {
        ModelSectionCard(
            title: title,
            icon: icon,
            models: models,
            collapsedModels: collapsedModels,
            isExpanded: isExpanded,
            dividerLeadingPadding: Self.dividerLeadingPadding,
            cornerRadius: Self.cornerRadius
        ) { model in
            row(for: model)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for model: ModelConfig) -> some View {
        let isSelected = enabledIDs.contains(model.id)
        if model.isDirectTranslation {
            SelectableModelRow(
                model: model,
                isSelected: isSelected,
                subtitle: model.id == ModelConfig.appleTranslateID
                    ? String(localized: "Private & On-Device")
                    : String(localized: "Free, no API key needed"),
                additionalBadges: [
                    model.id == ModelConfig.appleTranslateID
                        ? SelectableModelRow.Badge(String(localized: "On-Device"), color: .green)
                        : SelectableModelRow.Badge(String(localized: "Free"), color: .blue),
                ],
                showsDefaultBadge: false,
                showsPremiumCrown: false,
                showsModelTags: false
            ) {
                select(model)
            }
            if model.id == ModelConfig.appleTranslateID, isSelected, !isSingleSelection {
                installedLanguagesSection
            }
        } else if model.isFoundationModel {
            let isAvailable = FoundationModelService.availability(for: model).isAvailable
            SelectableModelRow(
                model: model,
                isSelected: isSelected,
                isDimmed: !isAvailable && !isSelected,
                subtitle: FoundationModelService.availabilityDescription(for: model),
                additionalBadges: [
                    SelectableModelRow.Badge(
                        model.isPrivateCloudModel ? String(localized: "Private Cloud") : String(localized: "On-Device"),
                        color: model.isPrivateCloudModel ? .blue : .green
                    ),
                ],
                showsDefaultBadge: false,
                showsPremiumCrown: false,
                showsModelTags: false
            ) {
                select(model)
            }
        } else {
            let isLocked = model.isPremium && !entitlement.isPro
            SelectableModelRow(
                model: model,
                isSelected: isSelected,
                isLocked: isLocked,
                isDimmed: hasReachedFreeLimit && !isSelected && !isLocked,
                subtitle: model.id
            ) {
                select(model)
            }
        }
    }

    private var installedLanguages: [TargetLanguageOption] {
        let installed = preferences.appleTranslateInstalledLanguages
        guard !installed.isEmpty else { return [] }
        return TargetLanguageOption.selectionOptions
            .filter { $0 != .appLanguage && installed.contains($0.rawValue) }
    }

    @ViewBuilder
    private var installedLanguagesSection: some View {
        let languages = installedLanguages
        Divider()
            .padding(.leading, Self.dividerLeadingPadding)

        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                showInstalledLanguages.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: showInstalledLanguages ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(colors.textSecondary.opacity(0.55))
                Text("\(languages.count) languages downloaded")
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
            ForEach(languages) { language in
                Divider()
                    .padding(.leading, Self.dividerLeadingPadding)
                HStack(spacing: 8) {
                    Text(language.nativeName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                    Text(language.englishName)
                        .font(.system(size: 13))
                        .foregroundColor(colors.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            Divider()
                .padding(.leading, Self.dividerLeadingPadding)

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

    private var upgradeButton: some View {
        Button {
            onRequiresPro?()
        } label: {
            Text("Upgrade")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func loadErrorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(colors.error)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(colors.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await loadCloudModels() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Selection

    private func select(_ model: ModelConfig) {
        if model.isFoundationModel, !enabledIDs.contains(model.id) {
            let availability = FoundationModelService.availability(for: model)
            guard availability.isAvailable else {
                alert = AlertContent(title: "Apple Intelligence", message: availability.localizedDescription)
                return
            }
        }

        Task {
            let isPro = await entitlement.refreshAndGetIsPro()
            switch mode {
            case let .single(selection, _, onSelected):
                guard !model.isPremium || isPro else {
                    requirePro()
                    return
                }
                selection.wrappedValue = model
                onSelected()
            case .enabledModels:
                toggle(model, isPro: isPro)
            }
        }
    }

    private func toggle(_ model: ModelConfig, isPro: Bool) {
        let oldIDs = enabledIDs
        let result = ModelSelectionPolicy.toggle(
            model,
            enabledIDs: oldIDs,
            availableModels: selectableModels,
            isPro: isPro
        )

        switch result.reason {
        case .requiresPro:
            requirePro()
            return
        case .freeCloudModelLimitReached:
            showAlert(for: .freeCloudModelLimitReached)
            return
        case .keptDefaultModel:
            showAlert(for: .keptDefaultModel)
        case nil:
            break
        }

        guard result.enabledIDs != oldIDs else { return }
        preferences.setEnabledModelIDs(result.enabledIDs)

        let hadAppleTranslate = oldIDs.contains(ModelConfig.appleTranslateID)
        let hasAppleTranslate = result.enabledIDs.contains(ModelConfig.appleTranslateID)
        if hasAppleTranslate, !hadAppleTranslate {
            refreshInstalledLanguages()
        } else if hadAppleTranslate, !hasAppleTranslate {
            preferences.setAppleTranslateInstalledLanguages([])
        }
    }

    private func requirePro() {
        if let onRequiresPro {
            onRequiresPro()
        } else {
            showAlert(for: .requiresPro)
        }
    }

    private func showAlert(for reason: ModelSelectionPolicy.Reason) {
        let message = switch reason {
        case .freeCloudModelLimitReached:
            String(localized: "Free users can select up to \(ModelSelectionPolicy.freeCloudModelLimit) cloud models.")
        case .requiresPro:
            String(localized: "Upgrade to use premium models.")
        case .keptDefaultModel:
            String(localized: "At least one model stays selected.")
        }
        alert = AlertContent(title: "Models", message: message)
    }

    // MARK: - Loading

    private func refreshInstalledLanguages() {
        guard !SnapshotLaunchArguments.isSnapshotMode() else { return }
        Task {
            guard AppleTranslationService.shared.isAvailable else { return }
            if #available(iOS 17.4, macOS 14.4, *) {
                let installed = await AppleTranslationService.shared.refreshInstalledLanguages()
                preferences.setAppleTranslateInstalledLanguages(Set(installed.map(\.rawValue)))
            }
        }
    }

    private func loadCloudModels() async {
        guard !isSingleSelection else { return }

        if SnapshotLaunchArguments.isSnapshotMode(), SnapshotLaunchArguments.fixture() == .aiModels {
            cloudModels = SnapshotFixtureData.cloudModels(for: .aiModels)
            preferences.setEnabledModelIDs([
                ModelConfig.appleTranslateID,
                ModelConfig.microsoftTranslateID,
                "gpt-5-nano",
                "deepseek-v3",
            ])
            preferences.setAppleTranslateInstalledLanguages(["en", "zh-Hans"])
            return
        }

        isLoading = true
        loadErrorMessage = nil
        defer { isLoading = false }
        do {
            let fetched = try await ModelsService.shared.fetchModels(forceRefresh: true)
            cloudModels = fetched
            if preferences.enabledModelIDs.isEmpty {
                preferences.setEnabledModelIDs(Set(fetched.filter(\.isDefault).map(\.id)))
            }
        } catch is CancellationError {
            return
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }
}

private extension ModelListSection {
    var title: LocalizedStringKey {
        switch self {
        case .translation: "TRANSLATION"
        case .appleIntelligence: "APPLE INTELLIGENCE"
        case .free: "FREE MODELS"
        case .premium: "PREMIUM MODELS"
        }
    }

    var icon: String {
        switch self {
        case .translation: "globe"
        case .appleIntelligence: "apple.intelligence"
        case .free: "cpu"
        case .premium: "crown.fill"
        }
    }
}

/// One flat list: each group row is followed by its models. Dragging a group row reorders groups;
/// a model only moves within its own group, and a drop outside it snaps back.
private struct ModelListOrderSheet: View {
    private enum Row: Identifiable {
        case group(ModelListSection)
        case model(ModelConfig, in: ModelListSection)

        var id: String {
            switch self {
            case let .group(section): "group.\(section.rawValue)"
            case let .model(model, section): "model.\(section.rawValue).\(model.id)"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var preferences = AppPreferences.shared
    /// Rebuilds the rows after a rejected move so the list drops the row's visual position.
    @State private var listRevision = 0

    let cloudModels: [ModelConfig]

    private var order: ModelListOrder {
        preferences.modelListOrder
    }

    private var rows: [Row] {
        order.orderedSections.flatMap { section in
            [Row.group(section)] + order.models(in: section, cloudModels: cloudModels).map { Row.model($0, in: section) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { row in
                        switch row {
                        case let .group(section):
                            groupRow(section)
                        case let .model(model, _):
                            modelRow(model)
                        }
                    }
                    .onMove(perform: move)
                } footer: {
                    Text("Results sorted by Model List Order follow this order.")
                }
            }
            .id(listRevision)
            #if os(iOS)
                .listStyle(.insetGrouped)
                .environment(\.editMode, .constant(.active))
                .navigationBarTitleDisplayMode(.inline)
            #else
                .listStyle(.inset)
            #endif
                .navigationTitle("Reorder")
                .toolbar {
                    ToolbarItem(placement: resetPlacement) {
                        Button("Reset", role: .destructive) {
                            preferences.setModelListOrder(ModelListOrder())
                        }
                        .disabled(order == ModelListOrder())
                        .accessibilityIdentifier("models.reorder.reset")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 480, idealHeight: 640)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var resetPlacement: ToolbarItemPlacement {
        #if os(iOS)
            .topBarLeading
        #else
            .destructiveAction
        #endif
    }

    private static let iconSize: CGFloat = 24
    private static let iconSpacing: CGFloat = 12

    private func groupRow(_ section: ModelListSection) -> some View {
        HStack(spacing: Self.iconSpacing) {
            Image(systemName: section.icon)
                .font(.body)
                .foregroundStyle(section == .premium ? Color.orange : AppColors.palette(for: colorScheme).accent)
                .frame(width: Self.iconSize)
                .accessibilityHidden(true)
            Text(section.name)
                .font(.headline)
            Spacer(minLength: 8)
            dragHandle
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("models.reorder.group.\(section.rawValue)")
    }

    private func modelRow(_ model: ModelConfig) -> some View {
        let isEnabled = preferences.enabledModelIDs.contains(model.id)
        let isUnavailable = model.isFoundationModel && !FoundationModelService.availability(for: model).isAvailable
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .foregroundStyle(isUnavailable ? .secondary : .primary)
                if !model.isDirectTranslation, !model.isFoundationModel {
                    Text(model.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isEnabled {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            dragHandle
        }
        // Aligns model names with the group title.
        .padding(.leading, Self.iconSize + Self.iconSpacing)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isEnabled ? .isSelected : [])
        .accessibilityIdentifier("models.reorder.model.\(model.id)")
    }

    /// iOS edit mode draws its own handle; macOS lists drag rows directly and show none.
    @ViewBuilder
    private var dragHandle: some View {
        #if os(macOS)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        #endif
    }

    private func move(from source: IndexSet, to destination: Int) {
        let current = rows
        var moved = current
        moved.move(fromOffsets: source, toOffset: destination)

        var order = order
        if source.contains(where: { if case .group = current[$0] { true } else { false } }) {
            order.sections = moved.compactMap { row in
                if case let .group(section) = row { section } else { nil }
            }
        } else {
            // A model belongs to the group row above it; any move that changes that is rejected.
            var owner: ModelListSection?
            var idsBySection: [ModelListSection: [String]] = [:]
            for row in moved {
                switch row {
                case let .group(section):
                    owner = section
                case let .model(model, section):
                    guard owner == section else {
                        listRevision += 1
                        return
                    }
                    idsBySection[section, default: []].append(model.id)
                }
            }
            for (section, ids) in idsBySection {
                order.modelIDsBySection[section.rawValue] = ids
            }
        }
        withAnimation {
            preferences.setModelListOrder(order)
        }
    }
}

private extension ModelListSection {
    var name: LocalizedStringKey {
        switch self {
        case .translation: "Translation"
        case .appleIntelligence: "Apple Intelligence"
        case .free: "Free Models"
        case .premium: "Premium Models"
        }
    }
}
