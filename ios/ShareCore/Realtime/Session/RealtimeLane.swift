#if os(macOS) || os(iOS)
    import Foundation

    public struct RealtimeLaneConfiguration: Codable, Identifiable, Hashable, Sendable {
        private enum CodingKeys: String, CodingKey {
            case id
            case recognitionModelID
            case translationProvider
        }

        private static let retiredAzureProviderID = "azure_gpt_realtime_translator"

        public let id: UUID
        public var recognitionModelID: String
        public var translationProvider: RealtimeTranslationProvider

        public init(
            id: UUID = UUID(),
            recognitionModelID: String,
            translationProvider: RealtimeTranslationProvider
        ) {
            self.id = id
            self.recognitionModelID = recognitionModelID
            self.translationProvider = translationProvider
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            recognitionModelID = try container.decode(String.self, forKey: .recognitionModelID)
            let providerID = try container.decode(String.self, forKey: .translationProvider)
            if providerID == Self.retiredAzureProviderID {
                translationProvider = .appleTranslator
            } else {
                guard let provider = RealtimeTranslationProvider(rawValue: providerID) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .translationProvider,
                        in: container,
                        debugDescription: "Unsupported realtime translation provider"
                    )
                }
                translationProvider = provider
            }
        }

        public var recognitionModel: RecognitionModelDescriptor {
            RecognitionModelStore.selectableDescriptor(forModelID: recognitionModelID)
        }

        public var title: String {
            "\(recognitionModel.title) → \(translationProvider.title)"
        }
    }

    public struct RealtimeLaneLatency: Equatable, Sendable {
        public let recognitionMilliseconds: Int
        /// `nil` until the first translation of the session completes, or when the lane does not translate.
        public let translationMilliseconds: Int?

        public var totalMilliseconds: Int {
            recognitionMilliseconds + (translationMilliseconds ?? 0)
        }

        public init(
            recognitionLatency: TimeInterval,
            translationLatency: TimeInterval?
        ) {
            recognitionMilliseconds = Self.milliseconds(from: recognitionLatency)
            translationMilliseconds = translationLatency.map(Self.milliseconds(from:))
        }

        public init(recognitionMilliseconds: Int, translationMilliseconds: Int?) {
            self.recognitionMilliseconds = recognitionMilliseconds
            self.translationMilliseconds = translationMilliseconds
        }

        private static func milliseconds(from duration: TimeInterval) -> Int {
            Int((max(0, duration) * 1000).rounded())
        }
    }

    public struct RealtimeLaneSnapshot: Identifiable, Equatable, Sendable {
        public enum Phase: String, Equatable, Sendable {
            case ready
            case loading
            case listening
            case recognizing
            case translating
            case paused
            case stopped
            case failed
        }

        public let id: UUID
        public var configuration: RealtimeLaneConfiguration
        public var phase: Phase
        public var sourceText: String
        public var translatedText: String
        public var pendingSourceText: String
        public var pendingTranslatedText: String
        public var sentencePairs: [SentencePair]
        public var captionLines: [RealtimeCaptionLine]
        public var startedOffset: TimeInterval
        public var endedOffset: TimeInterval?
        public var errorMessage: String?
        public var latency: RealtimeLaneLatency?

        public init(
            configuration: RealtimeLaneConfiguration,
            phase: Phase = .ready,
            sourceText: String = "",
            translatedText: String = "",
            pendingSourceText: String = "",
            pendingTranslatedText: String = "",
            sentencePairs: [SentencePair] = [],
            captionLines: [RealtimeCaptionLine] = [],
            startedOffset: TimeInterval = 0,
            endedOffset: TimeInterval? = nil,
            errorMessage: String? = nil,
            latency: RealtimeLaneLatency? = nil
        ) {
            id = configuration.id
            self.configuration = configuration
            self.phase = phase
            self.sourceText = sourceText
            self.translatedText = translatedText
            self.pendingSourceText = pendingSourceText
            self.pendingTranslatedText = pendingTranslatedText
            self.sentencePairs = sentencePairs
            self.captionLines = captionLines
            self.startedOffset = startedOffset
            self.endedOffset = endedOffset
            self.errorMessage = errorMessage
            self.latency = latency
        }
    }

    enum RealtimeLaneConfigurationPersistence {
        private static let configurationsKey = "realtime_lane_configurations"
        private static let primaryLaneIDKey = "realtime_primary_lane_id"

        static func load(
            defaults: UserDefaults,
            fallbackRecognitionModelID: String,
            fallbackTranslationProvider: RealtimeTranslationProvider
        ) -> (configurations: [RealtimeLaneConfiguration], primaryLaneID: UUID) {
            if let data = defaults.data(forKey: configurationsKey),
               let decoded = try? JSONDecoder().decode([RealtimeLaneConfiguration].self, from: data),
               !decoded.isEmpty
            {
                var combinations = Set<String>()
                let configurations = decoded.compactMap { stored -> RealtimeLaneConfiguration? in
                    var migrated = stored
                    migrated.recognitionModelID =
                        stored.recognitionModelID == RecognitionModelDescriptor.mossTranscribeDiarize.id
                            ? RecognitionModelDescriptor.appleSpeech.id
                            : RecognitionModelStore.selectableDescriptor(forModelID: stored.recognitionModelID).id
                    let key = "\(migrated.recognitionModelID)|\(migrated.translationProvider.rawValue)"
                    return combinations.insert(key).inserted ? migrated : nil
                }
                .prefix(3)
                .map { $0 }
                guard let first = configurations.first else {
                    let configuration = RealtimeLaneConfiguration(
                        recognitionModelID: fallbackRecognitionModelID,
                        translationProvider: fallbackTranslationProvider
                    )
                    return ([configuration], configuration.id)
                }
                let storedPrimaryID = defaults.string(forKey: primaryLaneIDKey).flatMap(UUID.init(uuidString:))
                let primaryLaneID = storedPrimaryID.flatMap { candidate in
                    configurations.contains(where: { $0.id == candidate }) ? candidate : nil
                } ?? first.id
                if configurations != Array(decoded.prefix(3)) {
                    save(configurations: configurations, primaryLaneID: primaryLaneID, defaults: defaults)
                }
                return (configurations, primaryLaneID)
            }

            let configuration = RealtimeLaneConfiguration(
                recognitionModelID: fallbackRecognitionModelID,
                translationProvider: fallbackTranslationProvider
            )
            return ([configuration], configuration.id)
        }

        static func save(
            configurations: [RealtimeLaneConfiguration],
            primaryLaneID: UUID,
            defaults: UserDefaults
        ) {
            guard let data = try? JSONEncoder().encode(Array(configurations.prefix(3))) else { return }
            defaults.set(data, forKey: configurationsKey)
            defaults.set(primaryLaneID.uuidString, forKey: primaryLaneIDKey)
        }
    }
#endif
