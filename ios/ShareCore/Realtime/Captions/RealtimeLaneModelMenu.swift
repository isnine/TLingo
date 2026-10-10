#if os(macOS)
    import SwiftUI

    struct RealtimeLaneModelMenu: View {
        @ObservedObject var store: RealtimeSessionStore
        let configuration: RealtimeLaneConfiguration
        let colors: AppColors.Palette
        let sourceLanguage: SourceLanguageOption
        let isBusy: Bool

        @State private var isModelPickerPresented = false
        @State private var cachedModelIDs: Set<String> = []
        @State private var pendingDownloadModel: RecognitionModelDescriptor?
        @State private var desiredModelIDAfterDownload: String?
        @State private var modelDownloadProgress: [String: Double] = [:]
        @State private var modelDownloadError: String?
        @State private var modelDownloadTasks: [String: Task<Void, Never>] = [:]

        var body: some View {
            Button {
                isModelPickerPresented.toggle()
            } label: {
                HStack(spacing: 4) {
                    if !isLanguageSupported(configuration.recognitionModel) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                    }
                    Text(configuration.recognitionModel.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.bold())
                }
                .frame(minWidth: 0)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .help(selectedModelWarning ?? "")
            .popover(isPresented: $isModelPickerPresented, arrowEdge: .bottom) {
                modelPicker
            }
            .alert("Not Downloaded", isPresented: downloadConfirmationBinding) {
                Button("Cancel", role: .cancel) {
                    pendingDownloadModel = nil
                }
                Button("Download") {
                    guard let model = pendingDownloadModel else { return }
                    pendingDownloadModel = nil
                    downloadAndSelect(model)
                }
            } message: {
                if let model = pendingDownloadModel {
                    Text("\(model.title) · \(model.sizeDisplayName)")
                }
            }
            .onDisappear {
                for task in modelDownloadTasks.values {
                    task.cancel()
                }
                for modelID in modelDownloadTasks.keys {
                    store.removeModelDownload(id: modelID)
                }
                modelDownloadTasks.removeAll()
            }
        }

        private var modelPicker: some View {
            VStack(alignment: .leading, spacing: 2) {
                if let selectedModelWarning {
                    Label {
                        Text(selectedModelWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                    }
                    .font(.callout)
                    .foregroundStyle(colors.textPrimary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 4)
                }

                modelSection("On This Device", models: usableModels.filter(isModelCached))
                modelSection("Available to Download", models: usableModels.filter { !isModelCached($0) })
                modelSection("Unavailable", models: availableModels.filter { !isUsable($0) })

                if let modelDownloadError {
                    Text(modelDownloadError)
                        .font(.caption)
                        .foregroundStyle(colors.error)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                }
            }
            .padding(8)
            .frame(width: 320)
            .task {
                await refreshCachedModels()
            }
        }

        @ViewBuilder
        private func modelSection(_ title: LocalizedStringKey, models: [RecognitionModelDescriptor]) -> some View {
            if !models.isEmpty {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                ForEach(models) { model in
                    RealtimeLaneModelRow(
                        model: model,
                        detail: detailText(for: model),
                        isSelected: model.id == configuration.recognitionModel.id,
                        isUsable: isUsable(model),
                        colors: colors,
                        action: { selectModel(model) },
                        status: { modelStatusView(model) }
                    )
                }
            }
        }

        private var availableModels: [RecognitionModelDescriptor] {
            guard store.hasImportedAudio,
                  RecognitionModelStore.isRuntimeSupported(.mossTranscribeDiarize)
            else {
                return RecognitionModelStore.availableModels
            }
            return RecognitionModelStore.availableModels + [.mossTranscribeDiarize]
        }

        private var usableModels: [RecognitionModelDescriptor] {
            availableModels.filter(isUsable)
        }

        private var selectedModelWarning: String? {
            let model = configuration.recognitionModel
            guard !isLanguageSupported(model) else { return nil }
            return RecognitionModelDescriptor.unsupportedSourceLanguageMessage(
                modelTitle: model.title,
                languageName: sourceLanguage.primaryLabel
            )
        }

        private func isLanguageSupported(_ model: RecognitionModelDescriptor) -> Bool {
            model.supports(sourceLanguage: sourceLanguage)
        }

        private func isRuntimeAvailable(_ model: RecognitionModelDescriptor) -> Bool {
            model.runtime == .mossOffline
                ? RecognitionModelStore.isRuntimeSupported(model)
                : RecognitionModelStore.isSelectable(model)
        }

        private func isUsable(_ model: RecognitionModelDescriptor) -> Bool {
            isLanguageSupported(model) && isRuntimeAvailable(model)
        }

        /// Usable rows show capabilities; unusable rows show why they cannot be picked.
        private func detailText(for model: RecognitionModelDescriptor) -> String {
            if !isRuntimeAvailable(model) {
                return String(localized: "Unavailable on this device")
            }
            if !isLanguageSupported(model) || isModelCached(model) {
                return model.languageSummary
            }
            return model.limitsText
        }

        @ViewBuilder
        private func modelStatusView(_ model: RecognitionModelDescriptor) -> some View {
            if modelDownloadTasks[model.id] != nil {
                let progress = modelDownloadProgress[model.id] ?? 0
                HStack(spacing: 4) {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .frame(width: 18)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .monospacedDigit()
                }
            } else if isUsable(model), !isModelCached(model) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(colors.accent)
                    .help("Download")
            }
        }

        private var downloadConfirmationBinding: Binding<Bool> {
            Binding(
                get: { pendingDownloadModel != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDownloadModel = nil
                    }
                }
            )
        }

        private func isModelCached(_ model: RecognitionModelDescriptor) -> Bool {
            if model.runtime == .mossOffline {
                return cachedModelIDs.contains(model.id)
            }
            return model.download == nil || cachedModelIDs.contains(model.id)
        }

        private func selectModel(_ model: RecognitionModelDescriptor) {
            guard isUsable(model) else { return }
            modelDownloadError = nil
            if isModelCached(model) {
                desiredModelIDAfterDownload = nil
                store.updateLane(
                    id: configuration.id,
                    recognitionModelID: model.id,
                    translationProvider: configuration.translationProvider
                )
                isModelPickerPresented = false
                return
            }
            if modelDownloadTasks[model.id] != nil {
                desiredModelIDAfterDownload = model.id
                isModelPickerPresented = false
                return
            }
            pendingDownloadModel = model
        }

        private func refreshCachedModels() async {
            var cachedIDs = Set<String>()
            for model in RecognitionModelStore.availableModels {
                guard await RecognitionModelStore.shared.isModelCached(model) else { continue }
                cachedIDs.insert(model.id)
            }
            if await isMOSSModelCached() {
                cachedIDs.insert(RecognitionModelDescriptor.mossTranscribeDiarize.id)
            }
            cachedModelIDs = cachedIDs
        }

        private func downloadAndSelect(_ model: RecognitionModelDescriptor) {
            guard modelDownloadTasks[model.id] == nil else {
                desiredModelIDAfterDownload = model.id
                return
            }
            desiredModelIDAfterDownload = model.id
            modelDownloadProgress[model.id] = 0
            store.updateModelDownload(id: model.id, title: model.title, progress: 0)
            modelDownloadError = nil
            isModelPickerPresented = false
            modelDownloadTasks[model.id] = Task { @MainActor in
                let progressTask = Task { @MainActor in
                    while !Task.isCancelled {
                        let progress =
                            await downloadProgress(for: model) ??
                            modelDownloadProgress[model.id] ??
                            0
                        modelDownloadProgress[model.id] = progress
                        store.updateModelDownload(id: model.id, title: model.title, progress: progress)
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                defer {
                    progressTask.cancel()
                    modelDownloadTasks[model.id] = nil
                    modelDownloadProgress[model.id] = nil
                    store.removeModelDownload(id: model.id)
                }

                do {
                    if model.runtime == .mossOffline {
                        try await downloadMOSSModel()
                    } else {
                        try await RecognitionModelStore.shared.downloadModel(model)
                    }
                    cachedModelIDs.insert(model.id)
                    if desiredModelIDAfterDownload == model.id {
                        store.updateLane(
                            id: configuration.id,
                            recognitionModelID: model.id,
                            translationProvider: configuration.translationProvider
                        )
                        desiredModelIDAfterDownload = nil
                        isModelPickerPresented = false
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if desiredModelIDAfterDownload == model.id {
                        desiredModelIDAfterDownload = nil
                    }
                    modelDownloadError = "\(model.title): \(error.localizedDescription)"
                }
            }
        }

        private func downloadProgress(for model: RecognitionModelDescriptor) async -> Double? {
            guard model.runtime == .mossOffline else {
                return await RecognitionModelStore.shared.downloadProgress(for: model)
            }
            #if arch(arm64) && canImport(MLXAudioCore) && canImport(MLXAudioSTT)
                guard case let .downloading(fraction)? =
                    await RealtimeHistoryMOSSReconstructor.shared.currentProgress
                else {
                    return nil
                }
                return fraction
            #else
                return nil
            #endif
        }

        private func isMOSSModelCached() async -> Bool {
            #if arch(arm64) && canImport(MLXAudioCore) && canImport(MLXAudioSTT)
                return await RealtimeHistoryMOSSReconstructor.shared.isModelCached()
            #else
                return false
            #endif
        }

        private func downloadMOSSModel() async throws {
            #if arch(arm64) && canImport(MLXAudioCore) && canImport(MLXAudioSTT)
                try await RealtimeHistoryMOSSReconstructor.shared.ensureModelAvailable()
            #else
                throw RealtimeRecognizerError.unsupportedModel(
                    RecognitionModelDescriptor.mossTranscribeDiarize.id
                )
            #endif
        }
    }

    private struct RealtimeLaneModelRow<Status: View>: View {
        let model: RecognitionModelDescriptor
        let detail: String
        let isSelected: Bool
        let isUsable: Bool
        let colors: AppColors.Palette
        let action: () -> Void
        @ViewBuilder let status: () -> Status

        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(colors.accent)
                        .opacity(isSelected ? 1 : 0)
                        .frame(width: 14)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title)
                            .foregroundStyle(isUsable ? colors.textPrimary : colors.textSecondary)
                            .lineLimit(1)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(colors.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    status()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isUsable && isHovered ? colors.accent.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isUsable)
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
#endif
