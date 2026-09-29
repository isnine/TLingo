#if os(macOS) || os(iOS)
    import Foundation

    public enum RecognitionModelRuntime: String, Equatable, Sendable {
        case appleSpeech
        case coreML
        case fluidAudio
        case mossOffline
        case mlxStreaming
        case onnx
    }

    public enum RecognitionModelPlatform: String, Equatable, Hashable, Sendable {
        case iOS
        case macOS
    }

    public struct RecognitionModelDirectDownload: Equatable, Sendable {
        public let url: URL
        public let sha256: String
        public let expectedByteCount: Int64?

        public init(url: URL, sha256: String, expectedByteCount: Int64? = nil) {
            self.url = url
            self.sha256 = sha256
            self.expectedByteCount = expectedByteCount
        }
    }

    public enum RecognitionFluidAudioModel: String, Equatable, Sendable {
        case parakeetEOU320
        case parakeetEOU1280
        case nemotronStreaming560
        case nemotronStreaming1120
        case nemotronStreaming2240
        case nemotronMultilingual2240
    }

    public enum RecognitionModelDownload: Equatable, Sendable {
        case directFile(RecognitionModelDirectDownload)
        case fluidAudio(RecognitionFluidAudioModel)
        case huggingFace(repoID: String)
    }

    public struct RecognitionModelDescriptor: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let subtitle: String
        public let runtime: RecognitionModelRuntime
        public let supportedPlatforms: Set<RecognitionModelPlatform>
        public let supportedLanguageIDs: [String]
        public let sampleRate: Int
        public let sizeDisplayName: String
        public let isExperimental: Bool
        public let requiresAppleSilicon: Bool
        public let download: RecognitionModelDownload?
        public let license: String?

        public init(
            id: String,
            title: String,
            subtitle: String,
            runtime: RecognitionModelRuntime,
            supportedPlatforms: Set<RecognitionModelPlatform>,
            supportedLanguageIDs: [String],
            sampleRate: Int,
            sizeDisplayName: String,
            isExperimental: Bool = false,
            requiresAppleSilicon: Bool = false,
            download: RecognitionModelDownload?,
            license: String?
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.runtime = runtime
            self.supportedPlatforms = supportedPlatforms
            self.supportedLanguageIDs = supportedLanguageIDs
            self.sampleRate = sampleRate
            self.sizeDisplayName = sizeDisplayName
            self.isExperimental = isExperimental
            self.requiresAppleSilicon = requiresAppleSilicon
            self.download = download
            self.license = license
        }

        public var isAvailableOnCurrentPlatform: Bool {
            supportedPlatforms.contains(.current)
        }

        public var isSupportedOnCurrentDevice: Bool {
            isAvailableOnCurrentPlatform && (!requiresAppleSilicon || RecognitionModelPlatform.isAppleSilicon)
        }

        public var languageSummary: String {
            if id == Self.nemotronMultilingual2240.id {
                return String(
                    localized: "About 40 languages: English, Chinese, Japanese, Korean, French, Spanish, and more"
                )
            }
            if supportedLanguageIDs.isEmpty {
                return String(localized: "System languages")
            }
            if supportedLanguageIDs.count == 1, let languageID = supportedLanguageIDs.first {
                return String(localized: "\(Self.localizedLanguageName(for: languageID)) only")
            }
            return String(localized: "\(supportedLanguageIDs.count) languages")
        }

        public var recommendationText: String {
            switch id {
            case Self.appleSpeech.id:
                return String(localized: "Use for system-default recognition.")
            case Self.parakeetEOU320.id:
                return String(localized: "Use for low-latency English captions.")
            case Self.parakeetEOU1280.id:
                return String(localized: "Use for higher-accuracy English captions with natural EOU boundaries.")
            case Self.nemotronStreaming560.id:
                return String(localized: "Use for lower-latency English streaming recognition.")
            case Self.nemotronStreaming1120.id:
                return String(localized: "Use for higher-accuracy English streaming recognition.")
            case Self.nemotronStreaming2240.id:
                return String(localized: "Use for highest-accuracy English streaming recognition.")
            case Self.nemotronMultilingual2240.id:
                return String(localized: "Use for multilingual streaming recognition.")
            case Self.confuciusR2T2.id:
                return String(localized: "Use for low-latency Chinese and English streaming recognition.")
            default:
                return subtitle
            }
        }

        public var limitsText: String {
            "\(languageSummary) · \(sizeDisplayName)"
        }

        public func supports(sourceLanguage: SourceLanguageOption) -> Bool {
            sourceLanguage == .auto || supports(languageID: sourceLanguage.rawValue)
        }

        public func supports(languageID: String) -> Bool {
            guard !supportedLanguageIDs.isEmpty else { return true }
            let supported = Set(supportedLanguageIDs.map(Self.normalizedLanguageID))
            let normalized = Self.normalizedLanguageID(languageID)
            guard !supported.contains(normalized) else { return true }
            guard let base = normalized.split(separator: "-").first.map(String.init) else {
                return false
            }
            return supported.contains(base)
        }

        private static func normalizedLanguageID(_ languageID: String) -> String {
            languageID.replacingOccurrences(of: "_", with: "-").lowercased()
        }

        private static func localizedLanguageName(for languageID: String) -> String {
            Locale.current.localizedString(forIdentifier: normalizedLanguageID(languageID)) ?? languageID
        }
    }

    public extension RecognitionModelRuntime {
        var title: String {
            switch self {
            case .appleSpeech:
                return "Apple"
            case .coreML:
                return "Core ML"
            case .fluidAudio:
                return "FluidAudio"
            case .mossOffline, .mlxStreaming:
                return "MLX"
            case .onnx:
                return "ONNX"
            }
        }
    }

    public extension RecognitionModelPlatform {
        static var current: RecognitionModelPlatform {
            #if os(macOS)
                return .macOS
            #else
                return .iOS
            #endif
        }

        static var isAppleSilicon: Bool {
            #if arch(arm64)
                return true
            #else
                return false
            #endif
        }
    }

    public extension RecognitionModelDescriptor {
        static let appleSpeech = RecognitionModelDescriptor(
            id: "apple-speech",
            title: String(localized: "Apple Speech"),
            subtitle: String(localized: "Built-in system recognizer"),
            runtime: .appleSpeech,
            supportedPlatforms: [.iOS, .macOS],
            supportedLanguageIDs: [],
            sampleRate: 16000,
            sizeDisplayName: String(localized: "Built-in"),
            download: nil,
            license: nil
        )

        static let mossTranscribeDiarize = RecognitionModelDescriptor(
            id: "moss-transcribe-diarize",
            title: "MOSS Diarization",
            subtitle: "Imported audio transcription with speaker separation.",
            runtime: .mossOffline,
            supportedPlatforms: [.macOS],
            supportedLanguageIDs: [],
            sampleRate: 16000,
            sizeDisplayName: "1.83 GB",
            isExperimental: true,
            requiresAppleSilicon: true,
            download: nil,
            license: nil
        )

        static let parakeetEOU320 = RecognitionModelDescriptor(
            id: "parakeet-eou-320ms",
            title: "Parakeet EOU 320ms",
            subtitle: "Low-latency English streaming ASR powered by FluidAudio.",
            runtime: .fluidAudio,
            supportedPlatforms: [.iOS, .macOS],
            supportedLanguageIDs: ["en"],
            sampleRate: 16000,
            sizeDisplayName: "428.4 MiB",
            isExperimental: true,
            requiresAppleSilicon: true,
            download: .fluidAudio(.parakeetEOU320),
            license: "CC-BY-4.0"
        )

        static let parakeetEOU1280 = RecognitionModelDescriptor(
            id: "parakeet-eou-1280ms",
            title: "Parakeet EOU 1280ms",
            subtitle: "Higher-accuracy English streaming ASR with EOU boundaries.",
            runtime: .fluidAudio,
            supportedPlatforms: [.iOS, .macOS],
            supportedLanguageIDs: ["en"],
            sampleRate: 16000,
            sizeDisplayName: "419.2 MiB",
            isExperimental: true,
            requiresAppleSilicon: true,
            download: .fluidAudio(.parakeetEOU1280),
            license: "CC-BY-4.0"
        )

        static let nemotronStreaming560 = RecognitionModelDescriptor(
            id: "nemotron-streaming-560ms",
            title: "Nemotron Streaming 560ms",
            subtitle: "Lower-latency English streaming ASR powered by FluidAudio.",
            runtime: .fluidAudio,
            supportedPlatforms: [.iOS, .macOS],
            supportedLanguageIDs: ["en"],
            sampleRate: 16000,
            sizeDisplayName: "668.2 MiB",
            isExperimental: true,
            requiresAppleSilicon: true,
            download: .fluidAudio(.nemotronStreaming560),
            license: nil
        )

        static let nemotronStreaming1120 = RecognitionModelDescriptor(
            id: "nemotron-streaming-1120ms",
            title: "Nemotron Streaming 1120ms",
            subtitle: "Higher-accuracy English streaming ASR powered by FluidAudio.",
            runtime: .fluidAudio,
            supportedPlatforms: [.iOS, .macOS],
            supportedLanguageIDs: ["en"],
            sampleRate: 16000,
            sizeDisplayName: "668.2 MiB",
            isExperimental: true,
            requiresAppleSilicon: true,
            download: .fluidAudio(.nemotronStreaming1120),
            license: nil
        )

        static let nemotronStreaming2240 = RecognitionModelDescriptor(
            id: "nemotron-streaming-2240ms",
            title: "Nemotron Streaming 2240ms",
            subtitle: "Highest-accuracy English streaming ASR powered by FluidAudio.",
            runtime: .fluidAudio,
            supportedPlatforms: [.iOS, .macOS],
            supportedLanguageIDs: ["en"],
            sampleRate: 16000,
            sizeDisplayName: "598.4 MiB",
            isExperimental: true,
            requiresAppleSilicon: true,
            download: .fluidAudio(.nemotronStreaming2240),
            license: nil
        )

        static let nemotronMultilingual2240 = RecognitionModelDescriptor(
            id: "nemotron-multilingual-2240ms",
            title: "Nemotron 3.5 Multilingual 2240ms",
            subtitle: "Multilingual streaming ASR with language hints and automatic detection.",
            runtime: .fluidAudio,
            supportedPlatforms: [.iOS, .macOS],
            supportedLanguageIDs: [],
            sampleRate: 16000,
            sizeDisplayName: "634.0 MiB",
            isExperimental: true,
            requiresAppleSilicon: true,
            download: .fluidAudio(.nemotronMultilingual2240),
            license: nil
        )

        static let confuciusR2T2 = RecognitionModelDescriptor(
            id: "confucius4-r2t2-8bit",
            title: "Confucius4 R2T2",
            subtitle: "Append-only streaming ASR optimized for Chinese and English, powered by MLX.",
            runtime: .mlxStreaming,
            supportedPlatforms: [.macOS],
            supportedLanguageIDs: [],
            sampleRate: 16000,
            sizeDisplayName: "2.46 GB",
            isExperimental: true,
            requiresAppleSilicon: true,
            download: .huggingFace(repoID: "mlx-community/Confucius4-R2T2-8bit"),
            license: "NetEase Youdao Model Use License"
        )
    }
#endif
