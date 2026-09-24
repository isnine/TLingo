#if os(macOS) || os(iOS)
    import CryptoKit
    import Foundation
    #if os(macOS) && arch(arm64) && canImport(FluidAudio)
        import FluidAudio
    #endif

    public enum RecognitionModelStoreError: LocalizedError, Equatable {
        case missingDownload(String)
        case checksumMismatch(expected: String, actual: String)
        case unsupportedRuntime(String)

        public var errorDescription: String? {
            switch self {
            case let .missingDownload(modelID):
                return "Recognition model has no downloadable artifact: \(modelID)"
            case let .checksumMismatch(expected, actual):
                return "Recognition model checksum mismatch. Expected \(expected), got \(actual)."
            case let .unsupportedRuntime(modelID):
                return "Recognition model runtime is unavailable: \(modelID)"
            }
        }
    }

    public actor RecognitionModelStore {
        public static let shared = RecognitionModelStore()
        private static let retiredModelIDs: Set<String> = [
            "parakeet-tdt-0.6b-v2",
            "parakeet-tdt-0.6b-v3",
            "parakeet-flash",
            "qwen3-asr-int8",
        ]

        public static let knownModels: [RecognitionModelDescriptor] = [
            .appleSpeech,
            .mossTranscribeDiarize,
            .parakeetEOU320,
            .parakeetEOU1280,
            .nemotronStreaming560,
            .nemotronStreaming1120,
            .nemotronStreaming2240,
            .nemotronMultilingual2240,
            .confuciusR2T2,
        ]
        public static let selectableModels: [RecognitionModelDescriptor] = [
            .appleSpeech,
            .parakeetEOU320,
            .parakeetEOU1280,
            .nemotronStreaming560,
            .nemotronStreaming1120,
            .nemotronStreaming2240,
            .nemotronMultilingual2240,
            .confuciusR2T2,
        ]
        public static let allModels = knownModels
        public static let localModels: [RecognitionModelDescriptor] = [.appleSpeech]
        public static let experimentalModels: [RecognitionModelDescriptor] = [
            .parakeetEOU320,
            .parakeetEOU1280,
            .nemotronStreaming560,
            .nemotronStreaming1120,
            .nemotronStreaming2240,
            .nemotronMultilingual2240,
            .confuciusR2T2,
        ]
        public static var availableModels: [RecognitionModelDescriptor] {
            selectableModels.filter(\.isAvailableOnCurrentPlatform)
        }

        public static var defaultRealtimeModel: RecognitionModelDescriptor {
            #if os(macOS) && arch(arm64)
                if isRuntimeSupported(.nemotronStreaming1120) {
                    return .nemotronStreaming1120
                }
            #endif
            return .appleSpeech
        }

        private let fileManager: FileManager
        private let cacheDirectory: URL
        private let downloader = RecognitionModelDownloader()
        private var downloadProgress: [String: Double] = [:]
        private var downloadTasks: [String: Task<URL, Error>] = [:]

        public init(
            cacheDirectory: URL? = nil,
            fileManager: FileManager = .default
        ) {
            self.fileManager = fileManager
            self.cacheDirectory = cacheDirectory ?? fileManager
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RecognitionModels", isDirectory: true)
        }

        public static func descriptor(for engine: RealtimeRecognitionEngine) -> RecognitionModelDescriptor {
            switch engine {
            case .appleSpeech:
                return .appleSpeech
            }
        }

        public static func descriptor(forModelID modelID: String) -> RecognitionModelDescriptor? {
            knownModels.first { $0.id == modelID }
        }

        public static func selectableDescriptor(forModelID modelID: String) -> RecognitionModelDescriptor {
            if modelID == RecognitionModelDescriptor.mossTranscribeDiarize.id {
                return .mossTranscribeDiarize
            }
            if retiredModelIDs.contains(modelID) {
                return defaultRealtimeModel
            }
            guard let model = descriptor(forModelID: modelID),
                  selectableModels.contains(where: { $0.id == model.id }),
                  isRuntimeSupported(model)
            else {
                return .appleSpeech
            }
            return model
        }

        public static func isRuntimeSupported(_ model: RecognitionModelDescriptor) -> Bool {
            guard model.isSupportedOnCurrentDevice else { return false }
            switch model.runtime {
            case .appleSpeech:
                return true
            case .fluidAudio:
                return isFluidAudioRuntimeAvailable
            case .mossOffline:
                #if os(macOS) && arch(arm64)
                    return true
                #else
                    return false
                #endif
            case .mlxStreaming:
                #if os(macOS) && arch(arm64) && canImport(MLXAudioSTT)
                    return true
                #else
                    return false
                #endif
            case .coreML, .onnx:
                return false
            }
        }

        public static func isSelectable(_ model: RecognitionModelDescriptor) -> Bool {
            selectableModels.contains(where: { $0.id == model.id }) && isRuntimeSupported(model)
        }

        public func cachedModelURL(for model: RecognitionModelDescriptor) -> URL {
            cacheDirectory.appendingPathComponent(model.id, isDirectory: true)
        }

        public func downloadProgress(for model: RecognitionModelDescriptor) -> Double? {
            downloadProgress[model.id]
        }

        public func cachedModels(
            from models: [RecognitionModelDescriptor] = RecognitionModelStore.availableModels
        ) -> [RecognitionModelDescriptor] {
            models.filter { isModelCached($0) }
        }

        public func isModelCached(_ model: RecognitionModelDescriptor) -> Bool {
            guard let download = model.download else {
                return true
            }
            switch download {
            case .directFile:
                return fileManager.fileExists(atPath: artifactURL(for: model).path)
            case let .fluidAudio(fluidAudioModel):
                return isFluidAudioModelCached(fluidAudioModel, at: cachedModelURL(for: model))
            case .huggingFace:
                return isHuggingFaceSnapshotCached(at: cachedModelURL(for: model))
            }
        }

        @discardableResult
        public func downloadModel(_ model: RecognitionModelDescriptor) async throws -> URL {
            guard let download = model.download else {
                throw RecognitionModelStoreError.missingDownload(model.id)
            }
            if let task = downloadTasks[model.id] {
                return try await task.value
            }

            let task = Task {
                switch download {
                case let .directFile(directDownload):
                    return try await downloadDirectModel(model, download: directDownload)
                case let .fluidAudio(fluidAudioModel):
                    return try await downloadFluidAudioModel(fluidAudioModel, descriptor: model)
                case let .huggingFace(repoID):
                    return try await downloadHuggingFaceModel(repoID: repoID, descriptor: model)
                }
            }
            downloadTasks[model.id] = task
            defer {
                downloadTasks[model.id] = nil
            }
            return try await task.value
        }

        public func deleteModel(_ model: RecognitionModelDescriptor) throws {
            let url = cachedModelURL(for: model)
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        }

        private func downloadDirectModel(
            _ model: RecognitionModelDescriptor,
            download: RecognitionModelDirectDownload
        ) async throws -> URL {
            let modelDirectory = cachedModelURL(for: model)
            try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            let destination = artifactURL(for: model)

            downloadProgress[model.id] = 0
            do {
                if download.url.isFileURL {
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.copyItem(at: download.url, to: destination)
                    downloadProgress[model.id] = 1
                } else {
                    try await downloader.download(from: download.url, to: destination) { [weak self] progress in
                        Task { await self?.setDownloadProgress(progress, for: model.id) }
                    }
                }
            } catch {
                downloadProgress[model.id] = nil
                throw error
            }

            let actualChecksum = try sha256(for: destination)
            guard actualChecksum == download.sha256.lowercased() else {
                try? fileManager.removeItem(at: destination)
                downloadProgress[model.id] = nil
                throw RecognitionModelStoreError.checksumMismatch(expected: download.sha256, actual: actualChecksum)
            }

            downloadProgress[model.id] = nil
            return modelDirectory
        }

        private func artifactURL(for model: RecognitionModelDescriptor) -> URL {
            cachedModelURL(for: model).appendingPathComponent("artifact", isDirectory: false)
        }

        private func setDownloadProgress(_ progress: Double, for modelID: String) {
            downloadProgress[modelID] = progress
        }

        private func sha256(for url: URL) throws -> String {
            guard let inputStream = InputStream(url: url) else {
                throw URLError(.cannotOpenFile)
            }

            var hasher = SHA256()
            let bufferSize = 1024 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer {
                buffer.deallocate()
                inputStream.close()
            }

            inputStream.open()
            while true {
                let bytesRead = inputStream.read(buffer, maxLength: bufferSize)
                if bytesRead < 0 {
                    throw inputStream.streamError ?? URLError(.cannotOpenFile)
                }
                if bytesRead == 0 {
                    break
                }
                hasher.update(data: Data(bytes: buffer, count: bytesRead))
            }

            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        }

        private func isFluidAudioModelCached(_ model: RecognitionFluidAudioModel, at directory: URL) -> Bool {
            #if os(macOS) && arch(arm64) && canImport(FluidAudio)
                switch model {
                case .parakeetEOU320, .parakeetEOU1280:
                    let repo: Repo = model == .parakeetEOU320 ? .parakeetEou320 : .parakeetEou1280
                    let modelDirectory = directory
                        .appendingPathComponent(repo.folderName, isDirectory: true)
                    return ModelNames.ParakeetEOU.requiredModels.allSatisfy { modelName in
                        fluidAudioArtifactExists(at: modelDirectory.appendingPathComponent(modelName))
                    }
                case .nemotronStreaming560, .nemotronStreaming1120, .nemotronStreaming2240:
                    let repo: Repo = switch model {
                    case .nemotronStreaming560: .nemotronStreaming560
                    case .nemotronStreaming1120: .nemotronStreaming1120
                    default: .nemotronStreaming2240
                    }
                    let modelDirectory = directory.appendingPathComponent(repo.folderName, isDirectory: true)
                    return ModelNames.NemotronStreaming.requiredModels.allSatisfy { modelName in
                        fluidAudioArtifactExists(at: modelDirectory.appendingPathComponent(modelName))
                    }
                case .nemotronMultilingual2240:
                    let modelDirectory = directory
                        .appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
                        .appendingPathComponent("multilingual/2240ms", isDirectory: true)
                    let names = ModelNames.NemotronMultilingualStreaming.self
                    return [
                        names.preprocessor,
                        names.encoder,
                        names.decoder,
                        names.joint,
                    ].allSatisfy { name in
                        fluidAudioArtifactExists(at: modelDirectory.appendingPathComponent("\(name).mlmodelc")) ||
                            fluidAudioArtifactExists(at: modelDirectory.appendingPathComponent("\(name).mlpackage"))
                    } && [
                        names.tokenizer,
                        names.metadata,
                    ].allSatisfy { name in
                        fluidAudioArtifactExists(at: modelDirectory.appendingPathComponent(name))
                    }
                }
            #else
                return false
            #endif
        }

        private func fluidAudioArtifactExists(at url: URL) -> Bool {
            let payloadURL = switch url.pathExtension {
            case "mlmodelc":
                url.appendingPathComponent("model.mil")
            case "mlpackage":
                url.appendingPathComponent("Manifest.json")
            default:
                url
            }
            guard let attributes = try? fileManager.attributesOfItem(atPath: payloadURL.path),
                  let size = attributes[.size] as? NSNumber
            else {
                return false
            }
            return size.int64Value > 0
        }

        private func downloadFluidAudioModel(
            _ fluidAudioModel: RecognitionFluidAudioModel,
            descriptor: RecognitionModelDescriptor
        ) async throws -> URL {
            #if os(macOS) && arch(arm64) && canImport(FluidAudio)
                let modelDirectory = cachedModelURL(for: descriptor)
                if fileManager.fileExists(atPath: modelDirectory.path),
                   !isFluidAudioModelCached(fluidAudioModel, at: modelDirectory)
                {
                    try fileManager.removeItem(at: modelDirectory)
                }
                try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

                downloadProgress[descriptor.id] = 0
                do {
                    if fluidAudioModel == .nemotronMultilingual2240 {
                        let variantURL = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                            languageCode: "auto",
                            chunkMs: 2240,
                            to: modelDirectory,
                            progressHandler: { [weak self] progress in
                                Task {
                                    await self?.setDownloadProgress(
                                        progress.fractionCompleted,
                                        for: descriptor.id
                                    )
                                }
                            }
                        )
                        downloadProgress[descriptor.id] = nil
                        return variantURL
                    }

                    let repo: Repo = switch fluidAudioModel {
                    case .parakeetEOU320:
                        .parakeetEou320
                    case .parakeetEOU1280:
                        .parakeetEou1280
                    case .nemotronStreaming560:
                        .nemotronStreaming560
                    case .nemotronStreaming1120:
                        .nemotronStreaming1120
                    case .nemotronStreaming2240:
                        .nemotronStreaming2240
                    case .nemotronMultilingual2240:
                        preconditionFailure("Handled above")
                    }
                    try await ModelHub.download(
                        repo,
                        to: modelDirectory,
                        progressHandler: { [weak self] progress in
                            Task { await self?.setDownloadProgress(progress.fractionCompleted, for: descriptor.id) }
                        }
                    )
                } catch {
                    downloadProgress[descriptor.id] = nil
                    throw error
                }

                downloadProgress[descriptor.id] = nil
                return modelDirectory
            #else
                throw RecognitionModelStoreError.unsupportedRuntime(descriptor.id)
            #endif
        }
    }

    private extension RecognitionModelStore {
        func isHuggingFaceSnapshotCached(at directory: URL) -> Bool {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return false
            }
            let names = Set(enumerator.compactMap { ($0 as? URL)?.lastPathComponent })
            return names.contains("config.json") && names.contains("model.safetensors")
        }

        func downloadHuggingFaceModel(
            repoID: String,
            descriptor: RecognitionModelDescriptor
        ) async throws -> URL {
            #if os(macOS) && arch(arm64) && canImport(MLXAudioSTT)
                let modelDirectory = cachedModelURL(for: descriptor)
                downloadProgress[descriptor.id] = 0
                defer { downloadProgress[descriptor.id] = nil }
                try await RealtimeR2T2Recognizer.downloadSnapshot(repoID: repoID, to: modelDirectory) {
                    [weak self] fraction in
                    Task { await self?.setDownloadProgress(fraction, for: descriptor.id) }
                }
                return modelDirectory
            #else
                throw RecognitionModelStoreError.unsupportedRuntime(descriptor.id)
            #endif
        }
    }

    public extension RecognitionModelStore {
        static var isFluidAudioRuntimeAvailable: Bool {
            #if os(macOS) && arch(arm64) && canImport(FluidAudio)
                return true
            #else
                return false
            #endif
        }
    }

    private final class RecognitionModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private struct DownloadState {
            let destination: URL
            let progress: (Double) -> Void
            let continuation: CheckedContinuation<Void, Error>
            var isResolved = false
        }

        private let lock = NSLock()
        private var states: [Int: DownloadState] = [:]
        private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

        func download(
            from url: URL,
            to destination: URL,
            progress: @escaping (Double) -> Void
        ) async throws {
            let task = session.downloadTask(with: url)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    states[task.taskIdentifier] = DownloadState(
                        destination: destination,
                        progress: progress,
                        continuation: continuation
                    )
                    lock.unlock()
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }

        func urlSession(
            _: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData _: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
            lock.lock()
            let state = states[downloadTask.taskIdentifier]
            lock.unlock()
            state?.progress(progress)
        }

        func urlSession(
            _: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            lock.lock()
            guard var current = states[downloadTask.taskIdentifier], !current.isResolved else {
                lock.unlock()
                return
            }
            current.isResolved = true
            states[downloadTask.taskIdentifier] = current
            lock.unlock()

            do {
                let parent = current.destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: current.destination.path) {
                    try FileManager.default.removeItem(at: current.destination)
                }
                try FileManager.default.moveItem(at: location, to: current.destination)
                current.progress(1)
                current.continuation.resume()
            } catch {
                current.continuation.resume(throwing: error)
            }
        }

        func urlSession(
            _: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            lock.lock()
            guard let state = states.removeValue(forKey: task.taskIdentifier), !state.isResolved else {
                lock.unlock()
                return
            }
            lock.unlock()
            if let error {
                state.continuation.resume(throwing: error)
            }
        }
    }
#endif
