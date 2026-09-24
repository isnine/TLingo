//
//  ActionsView.swift
//  TLingo
//
//  Created by Codex on 2025/10/23.
//

import ShareCore
import SwiftUI
import UniformTypeIdentifiers

struct ActionsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var configurationStore: AppConfigurationStore
    @ObservedObject private var preferences = AppPreferences.shared
    private let embedsInNavigationStack: Bool

    init(configurationStore: AppConfigurationStore = .shared, embedsInNavigationStack: Bool = true) {
        self.configurationStore = configurationStore
        self.embedsInNavigationStack = embedsInNavigationStack
    }

    @State private var navigationPath = NavigationPath()
    @State private var isEditing = false
    @State private var isAddingNewAction = false
    @State private var isVoiceRecording = false
    @State private var voiceTranscript: String?
    @State private var aiGeneratedAction: ActionConfig?

    // Validation error state
    @State private var showValidationError = false
    @State private var validationErrorMessage = ""

    // Configuration import/export state
    @State private var isImportPresented = false
    @State private var isExportPresented = false
    @State private var isExporting = false
    @State private var configurationDocument: ConfigurationDocument?
    @State private var importError: String?
    @State private var showExportSuccess = false
    @State private var configEditorItem: ConfigEditorItem?

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        navigationContainer
            .tint(colors.accent)
            .sheet(isPresented: $isVoiceRecording) {
                if let transcript = voiceTranscript {
                    VoiceIntentConfirmationView(
                        transcript: transcript,
                        onActionSelected: { config in
                            aiGeneratedAction = config
                            voiceTranscript = nil
                            isVoiceRecording = false
                        },
                        onCancel: {
                            voiceTranscript = nil
                            isVoiceRecording = false
                        }
                    )
                    .presentationDetents([.large])
                } else {
                    VoiceRecordingView(
                        onComplete: { text in
                            voiceTranscript = text
                        },
                        onCancel: {
                            isVoiceRecording = false
                        }
                    )
                    .presentationDetents([.medium, .large])
                }
            }
            .alert("Validation Failed", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationErrorMessage)
            }
            .fileImporter(
                isPresented: $isImportPresented,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .fileExporter(
                isPresented: $isExportPresented,
                document: configurationDocument,
                contentType: .json,
                defaultFilename: exportFilename
            ) { result in
                handleExport(result)
            }
            .alert(
                "Import Failed",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "Unknown error")
            }
            .alert("Export Successful", isPresented: $showExportSuccess) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Configuration exported successfully.")
            }
            .sheet(item: $configEditorItem) { item in
                ConfigurationEditorView(
                    configInfo: item.configInfo,
                    initialText: item.text,
                    colors: colors,
                    onSave: { text in
                        saveEditedConfiguration(text)
                        configEditorItem = nil
                    },
                    onDismiss: {
                        configEditorItem = nil
                    }
                )
            }
            .overlay {
                if isExporting {
                    LoadingOverlay(
                        backgroundColor: colors.background.opacity(0.85),
                        messageFont: .system(size: 13),
                        textColor: colors.textSecondary,
                        accentColor: colors.accent
                    )
                }
            }
    }

    @ViewBuilder
    private var navigationContainer: some View {
        if embedsInNavigationStack {
            NavigationStack(path: $navigationPath) {
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
                if !preferences.voiceActionHintDismissed {
                    voiceActionHintCard
                }
                actionsSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
        }
        .background(colors.background.ignoresSafeArea())
        .navigationDestination(for: ActionConfig.self) { action in
            ActionDetailView(
                action: action,
                configurationStore: configurationStore,
                isReadOnly: configurationStore.isBuiltInAction(action)
            )
        }
        .navigationDestination(isPresented: $isAddingNewAction) {
            ActionDetailView(
                action: nil,
                configurationStore: configurationStore
            )
        }
        .navigationDestination(item: $aiGeneratedAction) { config in
            ActionDetailView(
                action: config,
                configurationStore: configurationStore,
                isAIGenerated: true
            )
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(colors.textSecondary)
                Text("ACTIONS")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(colors.textSecondary)

                Spacer()

                if !configurationStore.customActions.isEmpty {
                    Button {
                        withAnimation {
                            isEditing.toggle()
                        }
                    } label: {
                        Text(isEditing ? String(localized: "Done") : String(localized: "Reorder"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(colors.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .tlingoGlassCapsule(
                                tint: colors.accent.opacity(isEditing ? 0.16 : 0.08),
                                interactive: true,
                                fallbackTint: colors.accent.opacity(isEditing ? 0.12 : 0.06),
                                fallbackStroke: colors.accent.opacity(0.22)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    isVoiceRecording = true
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(colors.accent)
                        .frame(width: 30, height: 30)
                        .tlingoGlassCircle(
                            tint: colors.accent.opacity(0.18),
                            interactive: true,
                            fallbackTint: colors.accent.opacity(0.12),
                            fallbackStroke: colors.accent.opacity(0.24)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    isAddingNewAction = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(colors.accent)
                        .frame(width: 30, height: 30)
                        .tlingoGlassCircle(
                            tint: colors.cardBackground.opacity(0.14),
                            interactive: true,
                            fallbackTint: colors.inputBackground.opacity(0.86),
                            fallbackStroke: colors.divider
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 4)

            if configurationStore.actions.isEmpty {
                emptyStateView
            } else {
                // Actions list in card
                VStack(spacing: 0) {
                    ForEach(Array(configurationStore.actions.enumerated()), id: \.element.id) { index, action in
                        let isBuiltIn = configurationStore.isBuiltInAction(action)
                        Group {
                            if isBuiltIn {
                                NavigationLink(value: action) {
                                    ActionRowView(
                                        action: action,
                                        modelInfo: modelInfo(for: action),
                                        showDragHandle: false,
                                        colors: colors
                                    )
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink(value: action) {
                                    ActionRowView(
                                        action: action,
                                        modelInfo: modelInfo(for: action),
                                        showDragHandle: isEditing,
                                        colors: colors
                                    )
                                }
                                .buttonStyle(.plain)
                                .draggable(action.id.uuidString) {
                                    ActionRowView(
                                        action: action,
                                        modelInfo: modelInfo(for: action),
                                        showDragHandle: false,
                                        colors: colors
                                    )
                                    .frame(width: 300)
                                    .padding(16)
                                    .background(colors.cardBackground)
                                    .cornerRadius(12)
                                    .opacity(0.9)
                                }
                                .dropDestination(for: String.self) { items, _ in
                                    guard let draggedIDString = items.first,
                                          let draggedID = UUID(uuidString: draggedIDString)
                                    else {
                                        return false
                                    }
                                    reorderAction(from: draggedID, to: action.id)
                                    return true
                                }
                            }
                        }

                        if index < configurationStore.actions.count - 1 {
                            Divider()
                                .padding(.leading, isEditing ? 56 : 20)
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(actionsCardBackground)
            }
        }
    }

    @ViewBuilder
    private var actionsCardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(colors.cardBackground)
    }

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Actions")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(colors.textPrimary)
                Text("Configure your translation actions")
                    .font(.system(size: 16))
                    .foregroundColor(colors.textSecondary)
            }

            Spacer()

            configMenu
        }
    }

    private var configMenu: some View {
        Menu {
            Button {
                openConfigEditor()
            } label: {
                Label("Edit Configuration", systemImage: "doc.text")
            }

            Divider()

            Button {
                isImportPresented = true
            } label: {
                Label("Import Configuration", systemImage: "square.and.arrow.down")
            }

            Button {
                prepareAndExport()
            } label: {
                Label("Export Configuration", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(colors.textSecondary)
                .frame(width: 34, height: 34)
                .tlingoGlassCircle(
                    tint: colors.cardBackground.opacity(0.12),
                    interactive: true,
                    fallbackTint: colors.inputBackground.opacity(0.84),
                    fallbackStroke: colors.divider
                )
        }
        .padding(.top, 6)
    }

    private var voiceActionHintCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "mic.badge.plus")
                .foregroundColor(colors.accent)
                .font(.system(size: 18))

            Text("Try creating actions with your voice — just describe what you need!", comment: "Voice action hint")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button {
                preferences.setVoiceActionHintDismissed(true)
                isVoiceRecording = true
            } label: {
                Text("Try It", comment: "Voice action hint CTA")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(colors.chipPrimaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .tlingoGlassCapsule(
                        tint: colors.accent.opacity(0.72),
                        interactive: true,
                        fallbackTint: colors.accent,
                        fallbackStroke: colors.accent.opacity(0.22)
                    )
            }
            .buttonStyle(.plain)

            Button {
                preferences.setVoiceActionHintDismissed(true)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(colors.textSecondary)
                    .frame(width: 24, height: 24)
                    .tlingoGlassCircle(
                        tint: colors.cardBackground.opacity(0.10),
                        interactive: true,
                        fallbackTint: colors.inputBackground.opacity(0.84),
                        fallbackStroke: colors.divider
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .tlingoGlassSurface(
            cornerRadius: 12,
            tint: colors.cardBackground.opacity(0.14),
            fallbackTint: colors.cardBackground.opacity(0.86),
            fallbackStroke: colors.divider
        )
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(colors.textSecondary.opacity(0.4))

            VStack(spacing: 6) {
                Text("No Actions Yet")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(colors.textPrimary)

                Text("Tap + to create your first action")
                    .font(.system(size: 14))
                    .foregroundColor(colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .background(emptyStateCardBackground)
    }

    @ViewBuilder
    private var emptyStateCardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(colors.cardBackground)
    }

    struct ModelInfo {
        let modelCount: Int
        let modelNames: [String]
    }

    private func modelInfo(for _: ActionConfig) -> ModelInfo {
        let enabledModelIDs = AppPreferences.shared.enabledModelIDs
        return ModelInfo(
            modelCount: enabledModelIDs.count,
            modelNames: Array(enabledModelIDs)
        )
    }

    // MARK: - Configuration Import/Export

    private var exportFilename: String {
        let baseName = configurationStore.currentConfigurationName ?? "Configuration"
        let sanitized = ConfigurationFileManager.sanitizeFilename(baseName)
        let result = sanitized.isEmpty ? "Configuration" : sanitized
        if result.lowercased().hasSuffix(".json") {
            return result
        }
        return "\(result).json"
    }

    private func prepareAndExport() {
        isExporting = true
        // Convert to Sendable entries on main thread (lightweight)
        let entries = configurationStore.customActions.map { AppConfiguration.ActionEntry.from($0) }
        // Heavy JSON encoding runs off main thread
        Task.detached {
            let appConfig = AppConfiguration(actions: entries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(appConfig) else {
                await MainActor.run { isExporting = false }
                return
            }
            do {
                let doc = try ConfigurationDocument(data: data)
                await MainActor.run {
                    configurationDocument = doc
                    isExporting = false
                    isExportPresented = true
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    importError = error.localizedDescription
                }
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                importError = "Unable to access the selected file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                let importResult = ConfigurationService.shared.importConfiguration(from: data)

                switch importResult {
                case let .success(config):
                    let baseName = url.deletingPathExtension().lastPathComponent
                    let uniqueName = uniqueConfigurationName(from: baseName)
                    try ConfigurationFileManager.shared.saveConfiguration(config, name: uniqueName)
                    ConfigurationService.shared.applyConfiguration(
                        config,
                        to: configurationStore,
                        preferences: preferences,
                        configurationName: uniqueName
                    )
                case let .failure(error):
                    importError = error.localizedDescription
                }
            } catch {
                importError = error.localizedDescription
            }

        case let .failure(error):
            importError = error.localizedDescription
        }
    }

    private func handleExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            showExportSuccess = true
        case let .failure(error):
            importError = error.localizedDescription
        }
    }

    private func uniqueConfigurationName(from baseName: String) -> String {
        var candidate = baseName
        var counter = 2
        while ConfigurationFileManager.shared.configurationExists(named: candidate) {
            candidate = "\(baseName) \(counter)"
            counter += 1
        }
        return candidate
    }

    private func openConfigEditor() {
        isExporting = true
        // Convert to Sendable entries on main thread (lightweight)
        let entries = configurationStore.customActions.map { AppConfiguration.ActionEntry.from($0) }
        let name = configurationStore.currentConfigurationName ?? "Configuration"
        // Heavy JSON encoding runs off main thread
        Task.detached {
            let appConfig = AppConfiguration(actions: entries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(appConfig),
                  let jsonString = String(data: data, encoding: .utf8)
            else {
                await MainActor.run { isExporting = false }
                return
            }
            await MainActor.run {
                isExporting = false
                let info = ConfigurationFileInfo(
                    name: name,
                    url: URL(fileURLWithPath: "/"),
                    modifiedDate: Date()
                )
                configEditorItem = ConfigEditorItem(configInfo: info, text: jsonString)
            }
        }
    }

    private func saveEditedConfiguration(_ jsonString: String) {
        let result = ConfigurationService.shared.importConfiguration(from: jsonString)
        switch result {
        case let .success(config):
            let name = configurationStore.currentConfigurationName ?? "Default"
            try? ConfigurationFileManager.shared.saveConfiguration(config, name: name)
            ConfigurationService.shared.applyConfiguration(
                config,
                to: configurationStore,
                preferences: preferences,
                configurationName: name
            )
        case let .failure(error):
            importError = error.localizedDescription
        }
    }

    private func reorderAction(from sourceID: UUID, to destinationID: UUID) {
        guard sourceID != destinationID else { return }
        var actions = configurationStore.customActions
        guard let sourceIndex = actions.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = actions.firstIndex(where: { $0.id == destinationID })
        else {
            return
        }
        let movedAction = actions.remove(at: sourceIndex)
        actions.insert(movedAction, at: destinationIndex)
        switch configurationStore.updateCustomActions(actions) {
        case let .success(result) where result?.hasErrors == true:
            validationErrorMessage = result?.errors.map(\.message).joined(separator: "\n") ?? ""
            showValidationError = true
        case .success:
            break
        case let .failure(error):
            validationErrorMessage = error.localizedDescription
            showValidationError = true
        }
    }
}

private extension ActionsView {
    struct ActionRowView: View {
        let action: ActionConfig
        let modelInfo: ActionsView.ModelInfo
        let showDragHandle: Bool
        let colors: AppColorPalette

        var body: some View {
            HStack(spacing: 12) {
                if showDragHandle {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.textSecondary.opacity(0.6))
                        .frame(width: 24)
                }

                Image(systemName: action.outputType.systemImageName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(colors.accent)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(colors.accent.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.displayName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(colors.textPrimary)

                    HStack(spacing: 6) {
                        Text(action.prompt)
                            .lineLimit(1)
                        if modelInfo.modelCount > 0 {
                            Text("·")
                            Text(
                                String(
                                    format: NSLocalizedString("%lld models", comment: "Number of models"),
                                    Int64(modelInfo.modelCount)
                                )
                            )
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundColor(colors.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(colors.textSecondary.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }
}

#Preview {
    ActionsView()
        .preferredColorScheme(.dark)
}
