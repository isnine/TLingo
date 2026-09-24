#if os(macOS)
    import Foundation

    extension RealtimePipelineCoordinator {
        nonisolated static func distinctRecognitionModelIDs(
            in configurations: [RealtimeLaneConfiguration]
        ) -> [String] {
            var seen = Set<String>()
            return configurations.compactMap { configuration in
                let modelID = configuration.recognitionModel.id
                return seen.insert(modelID).inserted ? modelID : nil
            }
        }

        nonisolated static func validated(
            _ configurations: [RealtimeLaneConfiguration],
            physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
        ) throws -> [RealtimeLaneConfiguration] {
            guard !configurations.isEmpty else {
                throw RealtimePipelineError.missingLane
            }
            guard configurations.count <= maximumLaneCount else {
                throw RealtimePipelineError.maximumLaneCount
            }
            var combinations = Set<String>()
            for configuration in configurations {
                let key = "\(configuration.recognitionModelID)|\(configuration.translationProvider.rawValue)"
                guard combinations.insert(key).inserted else {
                    throw RealtimePipelineError.duplicateLane
                }
            }
            let fluidModelCount = Set(configurations.compactMap { configuration in
                let model = configuration.recognitionModel
                return model.runtime == .fluidAudio || model.runtime == .mlxStreaming ? model.id : nil
            }).count
            let maximumFluidModelCount: Int
            if physicalMemory < 24 * 1024 * 1024 * 1024 {
                maximumFluidModelCount = 1
            } else if physicalMemory < 32 * 1024 * 1024 * 1024 {
                maximumFluidModelCount = 2
            } else {
                maximumFluidModelCount = 3
            }
            guard fluidModelCount <= maximumFluidModelCount else {
                throw RealtimePipelineError.tooManyLocalRecognitionModels
            }
            return configurations
        }
    }

    enum RealtimePipelineError: LocalizedError, Equatable {
        case missingLane
        case maximumLaneCount
        case duplicateLane
        case modelNotDownloaded(String)
        case unsupportedTranslationProvider
        case memoryPressure
        case tooManyLocalRecognitionModels

        var errorDescription: String? {
            switch self {
            case .missingLane:
                return String(localized: "Add at least one realtime lane.")
            case .maximumLaneCount:
                return String(localized: "Realtime supports up to three lanes.")
            case .duplicateLane:
                return String(localized: "This recognition and translation combination already exists.")
            case let .modelNotDownloaded(modelName):
                return String(localized: "\(modelName) must be downloaded before starting realtime translation.")
            case .unsupportedTranslationProvider:
                return String(localized: "This translation provider cannot consume recognized text.")
            case .memoryPressure:
                return String(localized: "Wait for memory pressure to decrease before adding another realtime lane.")
            case .tooManyLocalRecognitionModels:
                return String(localized: "Reduce the number of distinct local recognition models on this Mac.")
            }
        }
    }

    public enum RealtimeStartBlocker: LocalizedError, Equatable {
        case missingLane
        case missingLanguageSelection
        case memoryPressure
        case tooManyLocalRecognitionModels
        case maximumLaneCount
        case duplicateLane
        case unsupportedRecognitionModel(String)
        case importedAudioRequired(String)
        case missingAzureConfiguration
        case starting
        case stopping

        init?(_ error: RealtimePipelineError) {
            switch error {
            case .missingLane:
                self = .missingLane
            case .maximumLaneCount:
                self = .maximumLaneCount
            case .duplicateLane:
                self = .duplicateLane
            case .memoryPressure:
                self = .memoryPressure
            case .tooManyLocalRecognitionModels:
                self = .tooManyLocalRecognitionModels
            case .modelNotDownloaded, .unsupportedTranslationProvider:
                return nil
            }
        }

        public var errorDescription: String? {
            switch self {
            case .missingLane:
                return String(localized: "Add a realtime view before starting.")
            case .missingLanguageSelection:
                return String(localized: "Choose source and target languages before starting.")
            case .memoryPressure:
                return String(
                    localized:
                    "Memory pressure is too high. Close memory-intensive apps, remove a view, or choose a lighter model."
                )
            case .tooManyLocalRecognitionModels:
                return String(
                    localized:
                    "This Mac cannot run this many different local models. Remove a view or reuse the same recognition model."
                )
            case .maximumLaneCount:
                return String(localized: "Realtime supports up to three views. Remove an extra view before starting.")
            case .duplicateLane:
                return String(
                    localized:
                    "Two views use the same recognition and translation models. Change a model or remove the duplicate view."
                )
            case let .unsupportedRecognitionModel(modelName):
                return String(localized: "\(modelName) is unavailable on this Mac. Choose another recognition model.")
            case let .importedAudioRequired(modelName):
                return String(localized: "\(modelName) requires imported audio. Import an audio file or choose another model.")
            case .missingAzureConfiguration:
                return String(
                    localized: "Add a valid Azure endpoint and API key in Realtime Options before starting."
                )
            case .starting:
                return String(localized: "Starting realtime translation")
            case .stopping:
                return String(localized: "Stopping realtime translation")
            }
        }
    }
#endif
