#if os(macOS) || os(iOS)
    import SwiftUI

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
        @State private var isExpanded = false

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
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text(isExpanded ? "Hide Models" : "Show All Models")
                            .font(.caption)
                        Spacer()
                        Text("\(models.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                ForEach(Array(visibleModels.enumerated()), id: \.element.id) { index, model in
                    modelRow(model)
                    if index < visibleModels.count - 1 {
                        Divider()
                    }
                }
            }
            .task {
                await refreshModelState()
            }
            .alert(Text("Source Language Not Supported"), isPresented: $isUnsupportedLanguageAlertPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(unsupportedLanguageMessage)
            }
            .onDisappear {
                for task in downloadTasks.values {
                    task.cancel()
                }
                downloadTasks.removeAll()
            }
        }

        private var visibleModels: [RecognitionModelDescriptor] {
            guard !isExpanded else { return models }
            let selectedModelID = RecognitionModelStore
                .selectableDescriptor(forModelID: preferences.realtimeRecognitionModelID)
                .id
            let selectedModels = models.filter { $0.id == selectedModelID }
            return selectedModels.isEmpty ? Array(models.prefix(1)) : selectedModels
        }

        private func modelRow(_ model: RecognitionModelDescriptor) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.title)
                            .font(.system(size: 13, weight: .semibold))

                        Text(model.recommendationText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(model.limitsText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 10)

                    actionView(for: model)
                }

                Text(detailText(for: model))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let error = downloadErrors[model.id] {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                if isDownloading(model) {
                    ProgressView(value: downloadProgress[model.id] ?? 0)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        @ViewBuilder
        private func actionView(for model: RecognitionModelDescriptor) -> some View {
            if !model.isSupportedOnCurrentDevice {
                Text("Unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isDownloading(model) {
                Button("Cancel") {
                    cancelDownload(model)
                }
                .disabled(isDisabled)
            } else if !isCached(model), model.download != nil {
                Button("Download") {
                    download(model)
                }
                .disabled(isDisabled)
            } else if RecognitionModelStore.isSelectable(model) {
                VStack(alignment: .trailing, spacing: 6) {
                    Button {
                        use(model)
                    } label: {
                        if isSelected(model) {
                            Text("Using")
                        } else {
                            Text("Use")
                        }
                    }
                    .disabled(isDisabled || isSelected(model))
                    if model.download != nil, !isSelected(model) {
                        Button("Delete") {
                            delete(model)
                        }
                        .disabled(isDisabled)
                    }
                }
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Runtime unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.download != nil, isCached(model) {
                        Button("Delete") {
                            delete(model)
                        }
                        .disabled(isDisabled)
                    }
                }
            }
        }

        private func detailText(for model: RecognitionModelDescriptor) -> String {
            if isDownloading(model) {
                return String(localized: "Downloading \(Int((downloadProgress[model.id] ?? 0) * 100))%")
            }
            if !model.isSupportedOnCurrentDevice {
                return String(localized: "Unavailable on this device")
            }
            if isSelected(model) {
                return String(localized: "Using")
            }
            if model.download == nil {
                return String(localized: "Ready")
            }
            if isCached(model) {
                return RecognitionModelStore.isSelectable(model) ?
                    String(localized: "Ready") :
                    String(localized: "Downloaded. Runtime unavailable.")
            }
            return String(localized: "Not Downloaded")
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
            downloadTasks[model.id] != nil
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
            for model in models {
                if await RecognitionModelStore.shared.isModelCached(model) {
                    cachedIDs.insert(model.id)
                }
                if let progress = await RecognitionModelStore.shared.downloadProgress(for: model) {
                    downloadProgress[model.id] = progress
                }
            }
            cachedModelIDs = cachedIDs
        }

        private func download(_ model: RecognitionModelDescriptor) {
            downloadErrors[model.id] = nil
            let task = Task {
                let progressTask = Task {
                    while !Task.isCancelled {
                        let progress = await RecognitionModelStore.shared.downloadProgress(for: model)
                        await MainActor.run {
                            downloadProgress[model.id] = progress ?? downloadProgress[model.id] ?? 0
                        }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                defer { progressTask.cancel() }

                do {
                    try await RecognitionModelStore.shared.downloadModel(model)
                } catch {
                    await MainActor.run {
                        if !RealtimeSessionStore.isCancellationError(error) {
                            downloadErrors[model.id] = Self.shortErrorDescription(error)
                        }
                    }
                }

                await MainActor.run {
                    downloadTasks[model.id] = nil
                    downloadProgress[model.id] = nil
                }
                await refreshModelState()
            }
            downloadTasks[model.id] = task
        }

        private func cancelDownload(_ model: RecognitionModelDescriptor) {
            downloadTasks[model.id]?.cancel()
            downloadTasks[model.id] = nil
            downloadProgress[model.id] = nil
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
