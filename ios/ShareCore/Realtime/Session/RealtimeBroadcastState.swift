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
            if let command = defaults.string(forKey: prefix + "stop") {
                state.stopRequested = command != defaults.string(forKey: prefix + "stopAcknowledged")
            }
            if state.stopRequested || defaults.bool(forKey: prefix + "draining") {
                state.phase = .stopping
            }
            return state
        }

        private func decodeState(forKey key: String) -> RealtimeBroadcastState? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? decoder.decode(RealtimeBroadcastState.self, from: data)
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
