#if os(iOS)
    import Foundation

    public struct RealtimeBroadcastState: Codable, Equatable, Sendable {
        public enum Phase: String, Codable, Equatable, Sendable {
            case idle
            case waiting
            case broadcasting
            case recognizing
            case translating
            case paused
            case stopping
            case stopped
            case failed
        }

        public static let staleTimeout: TimeInterval = 8

        public var sessionID: String
        public var phase: Phase
        public var sourceText: String
        public var translatedText: String
        public var translationSourceText: String
        public var sourceSegments: [String]
        public var sentencePairs: [SentencePair]
        public var pendingSourceText: String
        public var pendingTranslatedText: String
        public var audioSampleCount: Int
        public var audioLevel: Float?
        public var errorMessage: String?
        public var lastUpdatedAt: Date
        public var stopRequested: Bool
        public var realtimeHistorySession: RealtimeHistorySession?

        public init(
            sessionID: String = UUID().uuidString,
            phase: Phase = .idle,
            sourceText: String = "",
            translatedText: String = "",
            translationSourceText: String? = nil,
            sourceSegments: [String] = [],
            sentencePairs: [SentencePair] = [],
            pendingSourceText: String = "",
            pendingTranslatedText: String = "",
            audioSampleCount: Int = 0,
            audioLevel: Float? = nil,
            errorMessage: String? = nil,
            lastUpdatedAt: Date = Date(),
            stopRequested: Bool = false,
            realtimeHistorySession: RealtimeHistorySession? = nil
        ) {
            self.sessionID = sessionID
            self.phase = phase
            self.sourceText = sourceText
            self.translatedText = translatedText
            self.translationSourceText = translationSourceText ?? sourceText
            self.sourceSegments = sourceSegments
            self.sentencePairs = sentencePairs
            self.pendingSourceText = pendingSourceText
            self.pendingTranslatedText = pendingTranslatedText
            self.audioSampleCount = audioSampleCount
            self.audioLevel = audioLevel
            self.errorMessage = errorMessage
            self.lastUpdatedAt = lastUpdatedAt
            self.stopRequested = stopRequested
            self.realtimeHistorySession = realtimeHistorySession
        }

        enum CodingKeys: String, CodingKey {
            case sessionID
            case phase
            case sourceText
            case translatedText
            case translationSourceText
            case sourceSegments
            case sentencePairs
            case pendingSourceText
            case pendingTranslatedText
            case audioSampleCount
            case audioLevel
            case errorMessage
            case lastUpdatedAt
            case stopRequested
            case realtimeHistorySession
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? UUID().uuidString
            phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .idle
            sourceText = try container.decodeIfPresent(String.self, forKey: .sourceText) ?? ""
            translatedText = try container.decodeIfPresent(String.self, forKey: .translatedText) ?? ""
            translationSourceText = try container.decodeIfPresent(String.self, forKey: .translationSourceText) ?? sourceText
            sourceSegments = try container.decodeIfPresent([String].self, forKey: .sourceSegments) ?? []
            sentencePairs = try container.decodeIfPresent([SentencePair].self, forKey: .sentencePairs) ?? []
            pendingSourceText = try container.decodeIfPresent(String.self, forKey: .pendingSourceText) ?? ""
            pendingTranslatedText = try container.decodeIfPresent(String.self, forKey: .pendingTranslatedText) ?? ""
            audioSampleCount = try container.decodeIfPresent(Int.self, forKey: .audioSampleCount) ?? 0
            audioLevel = try container.decodeIfPresent(Float.self, forKey: .audioLevel)
            errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
            lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt) ?? Date()
            stopRequested = try container.decodeIfPresent(Bool.self, forKey: .stopRequested) ?? false
            realtimeHistorySession = try container.decodeIfPresent(
                RealtimeHistorySession.self,
                forKey: .realtimeHistorySession
            )
        }

        public func isStale(referenceDate: Date = Date(), timeout: TimeInterval = staleTimeout) -> Bool {
            referenceDate.timeIntervalSince(lastUpdatedAt) > timeout
        }

        public mutating func markBroadcastFinished() {
            if phase != .failed {
                phase = .stopped
            }
            stopRequested = false
        }
    }

    public final class RealtimeBroadcastStateStore: @unchecked Sendable {
        private static let stateKey = "realtime.broadcast.state"

        private let defaults: UserDefaults
        private let encoder = JSONEncoder()
        private let decoder = JSONDecoder()
        private let lock = NSLock()

        public convenience init?() {
            guard let defaults = UserDefaults(suiteName: AppPreferences.appGroupSuiteName) else {
                return nil
            }
            self.init(defaults: defaults)
        }

        public init(defaults: UserDefaults) {
            self.defaults = defaults
        }

        public func load() -> RealtimeBroadcastState? {
            lock.lock()
            defer { lock.unlock() }
            return loadLocked()
        }

        private func loadLocked() -> RealtimeBroadcastState? {
            guard let data = defaults.data(forKey: Self.stateKey) else { return nil }
            return try? decoder.decode(RealtimeBroadcastState.self, from: data)
        }

        public func save(_ state: RealtimeBroadcastState, synchronize: Bool = false) {
            lock.lock()
            defer { lock.unlock() }
            saveLocked(state, synchronize: synchronize)
        }

        private func saveLocked(_ state: RealtimeBroadcastState, synchronize: Bool) {
            guard let data = try? encoder.encode(state) else { return }
            defaults.set(data, forKey: Self.stateKey)
            if synchronize {
                defaults.synchronize()
            }
        }

        public func reset(sessionID: String = UUID().uuidString, phase: RealtimeBroadcastState.Phase = .idle) {
            save(RealtimeBroadcastState(sessionID: sessionID, phase: phase), synchronize: true)
        }

        public func update(synchronize: Bool = false, _ update: (inout RealtimeBroadcastState) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            var state = loadLocked() ?? RealtimeBroadcastState()
            update(&state)
            state.lastUpdatedAt = Date()
            saveLocked(state, synchronize: synchronize)
        }

        public func requestStop() {
            update(synchronize: true) { state in
                state.phase = .stopping
                state.stopRequested = true
            }
        }

        public func clearStopRequested() {
            update(synchronize: true) { $0.stopRequested = false }
        }
    }
#endif
