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
        /// Set by the extension once speech recognition has started and app audio is being used.
        public var isRecognitionReady: Bool
        /// Set by the host when it recognizes relayed audio itself; the extension's local
        /// pipeline never sets it, so it reads false once the extension falls back.
        public var usesHostRecognition: Bool
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
            isRecognitionReady: Bool = false,
            usesHostRecognition: Bool = false,
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
            self.isRecognitionReady = isRecognitionReady
            self.usesHostRecognition = usesHostRecognition
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
            case isRecognitionReady
            case usesHostRecognition
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
            isRecognitionReady = try container.decodeIfPresent(Bool.self, forKey: .isRecognitionReady) ?? false
            usesHostRecognition = try container.decodeIfPresent(Bool.self, forKey: .usesHostRecognition) ?? false
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

    public final class RealtimeBroadcastCompletion: @unchecked Sendable {
        private let store: RealtimeBroadcastStateStore
        public let sessionID: String
        private let lock = NSLock()
        private let drained = DispatchGroup()
        private var task: Task<Void, Never>?

        public init(store: RealtimeBroadcastStateStore, sessionID: String) {
            self.store = store
            self.sessionID = sessionID
        }

        @discardableResult
        public func finish(
            errorMessage: String? = nil,
            drain: @escaping @Sendable () async -> Void
        ) -> Task<Void, Never> {
            lock.lock()
            defer { lock.unlock() }
            if let task {
                return task
            }
            store.beginStopping(sessionID: sessionID)
            drained.enter()
            let task = Task.detached(priority: .userInitiated) { [self] in
                await drain()
                store.update(sessionID: sessionID, synchronize: true) { state in
                    state.markBroadcastFinished()
                    if let errorMessage {
                        state.errorMessage = errorMessage
                    }
                    if state.errorMessage != nil {
                        state.phase = .failed
                    }
                }
                drained.leave()
            }
            self.task = task
            return task
        }

        public func waitForDrain(timeout: TimeInterval) -> Bool {
            drained.wait(timeout: .now() + timeout) == .success
        }
    }

    public final class RealtimeBroadcastStateStore: @unchecked Sendable {
        // Only reset owns the active session. Producers write session-scoped snapshots,
        // so even a write already in flight cannot replace a newer host session.
        private static let stateKey = "realtime.broadcast.state"
        private static let sessionPrefix = "realtime.broadcast.session."

        private let defaults: UserDefaults
        private let encoder = JSONEncoder()
        private let decoder = JSONDecoder()
        private let lock = NSLock()
        /// Snapshots carry the whole transcript; reuse the last decode while the stored bytes are unchanged.
        private var decodeCache: [String: (data: Data, state: RealtimeBroadcastState)] = [:]

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
            guard let initial = decodeState(forKey: Self.stateKey) else { return nil }
            let prefix = Self.sessionPrefix + initial.sessionID + "."
            var state = decodeState(forKey: prefix + "terminal")
                ?? decodeState(forKey: prefix + "snapshot")
                ?? initial
            if state.phase == .stopped || state.phase == .failed {
                state.stopRequested = false
                return state
            }
            applyProducerActivity(to: &state, prefix: prefix)
            if let command = defaults.string(forKey: prefix + "stop") {
                state.stopRequested = command != defaults.string(forKey: prefix + "stopAcknowledged")
            }
            if state.stopRequested || defaults.bool(forKey: prefix + "draining") {
                state.phase = .stopping
            }
            return state
        }

        private func decodeState(forKey key: String) -> RealtimeBroadcastState? {
            guard let data = defaults.data(forKey: key) else {
                decodeCache[key] = nil
                return nil
            }
            if let cached = decodeCache[key], cached.data == data {
                return cached.state
            }
            guard let state = try? decoder.decode(RealtimeBroadcastState.self, from: data) else { return nil }
            decodeCache[key] = (data, state)
            return state
        }

        /// Liveness, sample count and level change several times a second; merging them from a small
        /// key keeps those writes from re-encoding the transcript snapshot.
        private func applyProducerActivity(to state: inout RealtimeBroadcastState, prefix: String) {
            guard let activity = defaults.dictionary(forKey: prefix + "activity"),
                  let timestamp = activity["at"] as? Double,
                  timestamp > state.lastUpdatedAt.timeIntervalSince1970
            else { return }
            state.lastUpdatedAt = Date(timeIntervalSince1970: timestamp)
            if let count = activity["count"] as? Int, count >= state.audioSampleCount {
                state.audioSampleCount = count
                state.audioLevel = activity["level"] as? Float
            }
        }

        public func save(_ state: RealtimeBroadcastState, synchronize: Bool = false) {
            lock.lock()
            defer { lock.unlock() }
            saveLocked(state, synchronize: synchronize)
        }

        private func saveLocked(_ state: RealtimeBroadcastState, synchronize: Bool) {
            if let initial = decodeState(forKey: Self.stateKey) {
                guard initial.sessionID == state.sessionID else { return }
            }
            let prefix = Self.sessionPrefix + state.sessionID + "."
            guard defaults.data(forKey: prefix + "terminal") == nil else { return }
            guard let data = try? encoder.encode(state) else { return }
            if defaults.data(forKey: Self.stateKey) == nil {
                defaults.set(data, forKey: Self.stateKey)
            }
            let isTerminal = state.phase == .stopped || state.phase == .failed
            defaults.set(data, forKey: prefix + (isTerminal ? "terminal" : "snapshot"))
            if synchronize {
                defaults.synchronize()
            }
        }

        public func reset(sessionID: String = UUID().uuidString, phase: RealtimeBroadcastState.Phase = .idle) {
            lock.lock()
            defer { lock.unlock() }
            let initial = RealtimeBroadcastState(sessionID: sessionID, phase: phase)
            guard let data = try? encoder.encode(initial) else { return }
            defaults.set(data, forKey: Self.stateKey)
            let activePrefix = Self.sessionPrefix + sessionID + "."
            for key in defaults.dictionaryRepresentation().keys
                where key.hasPrefix(Self.sessionPrefix) && !key.hasPrefix(activePrefix)
            {
                defaults.removeObject(forKey: key)
            }
            defaults.synchronize()
        }

        public func update(
            sessionID: String? = nil,
            synchronize: Bool = false,
            _ update: (inout RealtimeBroadcastState) -> Void
        ) {
            lock.lock()
            defer { lock.unlock() }
            var state = loadLocked() ?? RealtimeBroadcastState()
            guard sessionID == nil || state.sessionID == sessionID else { return }
            update(&state)
            state.lastUpdatedAt = Date()
            saveLocked(state, synchronize: synchronize)
        }

        public func requestStop() {
            lock.lock()
            defer { lock.unlock() }
            guard let state = loadLocked(), state.phase != .stopped, state.phase != .failed else { return }
            defaults.set(UUID().uuidString, forKey: Self.sessionPrefix + state.sessionID + ".stop")
            defaults.synchronize()
        }

        public func clearStopRequested() {
            lock.lock()
            defer { lock.unlock() }
            guard var state = loadLocked() else { return }
            let prefix = Self.sessionPrefix + state.sessionID + "."
            if let command = defaults.string(forKey: prefix + "stop") {
                // Acknowledge this command, never delete a concurrently issued replacement.
                defaults.set(command, forKey: prefix + "stopAcknowledged")
            }
            state.stopRequested = false
            saveLocked(state, synchronize: true)
        }

        /// Records producer liveness, and the audio count and level when given, without touching the snapshot.
        public func markProducerAlive(sessionID: String, audioSampleCount: Int? = nil, audioLevel: Float? = nil) {
            lock.lock()
            defer { lock.unlock() }
            let key = Self.sessionPrefix + sessionID + ".activity"
            guard defaults.object(forKey: Self.sessionPrefix + sessionID + ".terminal") == nil else { return }
            var activity = defaults.dictionary(forKey: key) ?? [:]
            activity["at"] = Date().timeIntervalSince1970
            if let audioSampleCount {
                activity["count"] = audioSampleCount
                activity["level"] = audioLevel.map { NSNumber(value: $0) }
            }
            defaults.set(activity, forKey: key)
        }

        /// Reads only the stop command keys, so the extension can poll without decoding the snapshot.
        public func isStopRequested(sessionID: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let prefix = Self.sessionPrefix + sessionID + "."
            guard decodeState(forKey: Self.stateKey)?.sessionID == sessionID,
                  defaults.object(forKey: prefix + "terminal") == nil,
                  let command = defaults.string(forKey: prefix + "stop")
            else { return false }
            return command != defaults.string(forKey: prefix + "stopAcknowledged")
        }

        /// Written by the host while it recognizes relayed audio; kept out of the state blob so the
        /// heartbeat never races the extension's snapshot writes.
        public func markHostAlive(sessionID: String) {
            defaults.set(Date().timeIntervalSince1970, forKey: Self.sessionPrefix + sessionID + ".hostHeartbeat")
        }

        /// Seconds since the host last marked itself alive for this session; nil if it never did.
        public func hostHeartbeatAge(sessionID: String) -> TimeInterval? {
            let timestamp = defaults.double(forKey: Self.sessionPrefix + sessionID + ".hostHeartbeat")
            guard timestamp > 0 else { return nil }
            return Date().timeIntervalSince1970 - timestamp
        }

        fileprivate func beginStopping(sessionID: String) {
            lock.lock()
            defer { lock.unlock() }
            guard let state = loadLocked(), state.sessionID == sessionID,
                  state.phase != .stopped, state.phase != .failed
            else { return }
            defaults.set(true, forKey: Self.sessionPrefix + sessionID + ".draining")
            defaults.synchronize()
        }
    }
#endif
