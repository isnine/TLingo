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
                modelDownloadTasks.removeAll()
            }
        }

        private var modelPicker: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(availableModels) { model in
                    Button {
                        selectModel(model)
                    } label: {
                        HStack(spacing: 12) {
                            Text(model.title)
                                .foregroundStyle(
                                    model.supports(sourceLanguage: sourceLanguage)
                                        ? colors.textPrimary
                                        : colors.textSecondary
                                )

                            Spacer(minLength: 16)

                            modelStatusView(model)
                                .frame(width: 52, height: 18, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        model.id == configuration.recognitionModel.id
                            ? colors.accent.opacity(0.12)
                            : Color.clear
                    )
                    .disabled(!model.supports(sourceLanguage: sourceLanguage))
                }

                if let modelDownloadError {
                    Divider()
                    Text(modelDownloadError)
                        .font(.caption)
                        .foregroundStyle(colors.error)
                        .padding(12)
                }
            }
            .frame(width: 280)
            .task {
                await refreshCachedModels()
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
            } else if isModelCached(model) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(colors.success)
                    .help("Downloaded")
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(colors.textSecondary)
                    .help("Not Downloaded")
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
            modelDownloadError = nil
            modelDownloadTasks[model.id] = Task { @MainActor in
                let progressTask = Task { @MainActor in
                    while !Task.isCancelled {
                        modelDownloadProgress[model.id] =
                            await downloadProgress(for: model) ??
                            modelDownloadProgress[model.id] ??
                            0
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                defer {
                    progressTask.cancel()
                    modelDownloadTasks[model.id] = nil
                    modelDownloadProgress[model.id] = nil
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
#endif
