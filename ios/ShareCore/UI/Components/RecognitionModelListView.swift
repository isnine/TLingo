#if os(macOS) || os(iOS)
    import SwiftUI

    /// Picker page for the realtime recognition model, meant to be pushed from a settings row.
    public struct RecognitionModelListView: View {
        @ObservedObject private var preferences: AppPreferences
        private let models: [RecognitionModelDescriptor]
        private let isDisabled: Bool

        @State private var cachedModelIDs: Set<String> = []
        @State private var downloadProgress: [String: Double] = [:]
        @State private var downloadErrors: [String: String] = [:]
        @State private var downloadTasks: [String: Task<Void, Never>] = [:]
        @State private var unsupportedLanguageMessage = ""
        @State private var isUnsupportedLanguageAlertPresented = false

        public init(
            preferences: AppPreferences = .shared,
            models: [RecognitionModelDescriptor],
            isDisabled: Bool
        ) {
            self.preferences = preferences
            self.models = models
            self.isDisabled = isDisabled
        }

        public var body: some View {
            Form {
                if isDisabled {
                    Section {
                        Label("Stop realtime to change the recognition model.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }

                modelSection("On This Device", models: models.filter { isAvailable($0) && isCached($0) })
                modelSection("Available to Download", models: models.filter { isAvailable($0) && !isCached($0) })
                modelSection("Unavailable", models: models.filter { !isAvailable($0) })
            }
            .navigationTitle("Recognition Model")
            // Downloads outlive this page, so poll the store whenever any download is in flight.
            .task(id: hasActiveDownloads) {
                await refreshModelState()
                while !Task.isCancelled, hasActiveDownloads {
                    try? await Task.sleep(for: .milliseconds(250))
                    await refreshModelState()
                }
            }
            .alert(Text("Source Language Not Supported"), isPresented: $isUnsupportedLanguageAlertPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(unsupportedLanguageMessage)
            }
        }

        @ViewBuilder
        private func modelSection(_ title: LocalizedStringKey, models: [RecognitionModelDescriptor]) -> some View {
            if !models.isEmpty {
                Section(title) {
                    ForEach(models) { model in
                        modelRow(model)
                    }
                }
            }
        }

        private func modelRow(_ model: RecognitionModelDescriptor) -> some View {
            Button {
                primaryAction(for: model)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.title)
                            .foregroundStyle(isAvailable(model) ? Color.primary : Color.secondary)

                        Text(model.recommendationText)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(model.limitsText)
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)

                        if let status = statusText(for: model) {
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                        }

                        if let error = downloadErrors[model.id] {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

                        if isDownloading(model) {
                            ProgressView(value: downloadProgress[model.id] ?? 0)
                                .padding(.top, 4)
                        }
                    }

                    Spacer(minLength: 8)

                    accessory(for: model)
                }
                .contentShape(Rectangle())
            }
            .disabled(isDisabled)
            .swipeActions(edge: .trailing) {
                if canDelete(model) {
                    Button("Delete", role: .destructive) {
                        delete(model)
                    }
                }
            }
            .contextMenu {
                if canDelete(model) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        delete(model)
                    }
                }
            }
            .accessibilityAddTraits(isSelected(model) ? .isSelected : [])
        }

        @ViewBuilder
        private func accessory(for model: RecognitionModelDescriptor) -> some View {
            if isDownloading(model) {
                Image(systemName: "stop.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Cancel")
            } else if isSelected(model) {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
            } else if isAvailable(model), !isCached(model) {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Download")
            }
        }

        private func primaryAction(for model: RecognitionModelDescriptor) {
            guard isAvailable(model) else { return }
            if isDownloading(model) {
                cancelDownload(model)
            } else if !isCached(model) {
                download(model)
            } else {
                use(model)
            }
        }

        private func statusText(for model: RecognitionModelDescriptor) -> String? {
            if !model.isSupportedOnCurrentDevice {
                return String(localized: "Unavailable on this device")
            }
            if !RecognitionModelStore.isSelectable(model) {
                return isCached(model) ?
                    String(localized: "Downloaded. Runtime unavailable.") :
                    String(localized: "Runtime unavailable")
            }
            return nil
        }

        private var hasActiveDownloads: Bool {
            !downloadTasks.isEmpty || !downloadProgress.isEmpty
        }

        private func isAvailable(_ model: RecognitionModelDescriptor) -> Bool {
            model.isSupportedOnCurrentDevice && RecognitionModelStore.isSelectable(model)
        }

        private func isSelected(_ model: RecognitionModelDescriptor) -> Bool {
            RecognitionModelStore
                .selectableDescriptor(forModelID: preferences.realtimeRecognitionModelID)
                .id == model.id
        }

        private func isCached(_ model: RecognitionModelDescriptor) -> Bool {
            model.download == nil || cachedModelIDs.contains(model.id)
        }

        private func isDownloading(_ model: RecognitionModelDescriptor) -> Bool {
            downloadTasks[model.id] != nil || downloadProgress[model.id] != nil
        }

        private func canDelete(_ model: RecognitionModelDescriptor) -> Bool {
            model.download != nil && cachedModelIDs.contains(model.id) && !isSelected(model) && !isDownloading(model)
        }

        private func use(_ model: RecognitionModelDescriptor) {
            guard model.supports(sourceLanguage: preferences.realtimeSourceLanguage) else {
                let sourceName = preferences.realtimeSourceLanguage.primaryLabel
                unsupportedLanguageMessage = String(
                    localized: "\(model.title) does not support \(sourceName). Choose a supported source language."
                )
                isUnsupportedLanguageAlertPresented = true
                return
            }
            preferences.setRealtimeRecognitionModelID(model.id)
        }

        private func refreshModelState() async {
            var cachedIDs = Set<String>()
            var progress: [String: Double] = [:]
            for model in models {
                if await RecognitionModelStore.shared.isModelCached(model) {
                    cachedIDs.insert(model.id)
                }
                if let value = await RecognitionModelStore.shared.downloadProgress(for: model) {
                    progress[model.id] = value
                }
            }
            cachedModelIDs = cachedIDs
            downloadProgress = progress
        }

        private func download(_ model: RecognitionModelDescriptor) {
            downloadErrors[model.id] = nil
            downloadTasks[model.id] = Task {
                do {
                    try await RecognitionModelStore.shared.downloadModel(model)
                } catch {
                    if !RealtimeSessionStore.isCancellationError(error) {
                        downloadErrors[model.id] = Self.shortErrorDescription(error)
                    }
                }
                downloadTasks[model.id] = nil
                await refreshModelState()
            }
        }

        private func cancelDownload(_ model: RecognitionModelDescriptor) {
            downloadTasks[model.id]?.cancel()
            Task { await RecognitionModelStore.shared.cancelDownload(model) }
        }

        private func delete(_ model: RecognitionModelDescriptor) {
            Task {
                do {
                    try await RecognitionModelStore.shared.deleteModel(model)
                    await refreshModelState()
                } catch {
                    downloadErrors[model.id] = Self.shortErrorDescription(error)
                }
            }
        }

        private static func shortErrorDescription(_ error: Error) -> String {
            if case RecognitionModelStoreError.checksumMismatch = error {
                return String(localized: "Checksum mismatch")
            }
            if case RecognitionModelStoreError.missingDownload = error {
                return String(localized: "No downloadable artifact")
            }
            return String(localized: "Download failed")
        }
    }
#endif
