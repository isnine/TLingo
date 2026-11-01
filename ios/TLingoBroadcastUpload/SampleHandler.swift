import CoreMedia
import Foundation
import ReplayKit
import ShareCore

final class SampleHandler: RPBroadcastSampleHandler {
    private let stateStore = RealtimeBroadcastStateStore() ?? RealtimeBroadcastStateStore(defaults: .standard)
    private let heartbeatQueue = DispatchQueue(label: "com.zanderwang.AITranslator.BroadcastUpload.heartbeat")
    private let finishLock = NSLock()
    private let heartbeatLock = NSLock()
    private var heartbeatTimer: DispatchSourceTimer?
    private let pipelineLock = NSLock()
    private var _pipeline: RealtimeLocalSpeechTranslationPipeline?
    private var _relayWriter: RealtimeAudioRelayWriter?
    private var relayedBufferCount = 0
    /// Set once the waiting phase has been advanced; later heartbeats only record liveness.
    private var hasReportedBroadcasting = false
    private var lastHostAgeLogAt = Date.distantPast
    private var completion: RealtimeBroadcastCompletion?

    /// The host must heartbeat within this window, or the extension recognizes locally with Apple Speech.
    private static let hostHeartbeatTimeout: TimeInterval = 5
    /// Shared-state writes per relayed buffer; matches the local pipeline's level cadence.
    private static let relayStateReportInterval = 8

    /// Read on ReplayKit's sample queue and cleared from heartbeat and failure callbacks.
    private var pipeline: RealtimeLocalSpeechTranslationPipeline? {
        get { pipelineLock.withLock { _pipeline } }
        set { pipelineLock.withLock { _pipeline = newValue } }
    }

    /// Set while the host recognizes relayed audio; at most one of `relayWriter` and `pipeline` is set.
    private var relayWriter: RealtimeAudioRelayWriter? {
        get { pipelineLock.withLock { _relayWriter } }
        set { pipelineLock.withLock { _relayWriter = newValue } }
    }

    private var didFinishBroadcast = false

    override func broadcastStarted(withSetupInfo _: [String: NSObject]?) {
        resetFinishState()
        relayedBufferCount = 0
        hasReportedBroadcasting = false
        let previous = stateStore.load()
        let sessionID: String
        if let previous, previous.phase != .stopped, previous.phase != .failed {
            sessionID = previous.sessionID
        } else {
            sessionID = UUID().uuidString
            stateStore.reset(sessionID: sessionID, phase: .waiting)
        }
        completion = RealtimeBroadcastCompletion(store: stateStore, sessionID: sessionID)
        let requestsHostRecognition = previous?.sessionID == sessionID && previous?.usesHostRecognition == true
        RealtimeAudioRelay.removeStaleSessions(keeping: requestsHostRecognition ? sessionID : nil)
        stateStore.update(sessionID: sessionID, synchronize: true) { state in
            state.sessionID = sessionID
            state.phase = .waiting
            state.sourceText = ""
            state.translatedText = ""
            state.translationSourceText = ""
            state.sentencePairs = []
            state.pendingSourceText = ""
            state.pendingTranslatedText = ""
            state.audioSampleCount = 0
            state.audioLevel = nil
            state.errorMessage = nil
            state.stopRequested = false
            state.isRecognitionReady = false
        }
        startHeartbeat()

        let hostAge = stateStore.hostHeartbeatAge(sessionID: sessionID)
        RealtimeLog.log(
            "broadcast",
            "extension started session=\(sessionID) reused=\(previous?.sessionID == sessionID) "
                + "requestsHost=\(requestsHostRecognition) hostAge=\(Self.format(hostAge))"
        )
        if requestsHostRecognition, let hostAge, hostAge < Self.hostHeartbeatTimeout,
           let writer = RealtimeAudioRelayWriter(sessionID: sessionID)
        {
            relayWriter = writer
            stateStore.update(sessionID: sessionID) { state in
                state.phase = .broadcasting
                state.isRecognitionReady = true
            }
            RealtimeLog.log("broadcast", "route=hostRelay session=\(sessionID)")
        } else {
            if requestsHostRecognition {
                RealtimeLog.warn(
                    "broadcast",
                    "route=local reason=hostUnavailable hostAge=\(Self.format(hostAge)) session=\(sessionID)"
                )
            } else {
                RealtimeLog.log("broadcast", "route=local reason=appleSpeechSelected session=\(sessionID)")
            }
            startLocalPipeline(sessionID: sessionID)
        }
    }

    private func startLocalPipeline(sessionID: String) {
        let pipeline = RealtimeLocalSpeechTranslationPipeline(stateStore: stateStore, sessionID: sessionID)
        pipeline.onFailure = { [weak self] error in
            self?.finishBroadcast(error)
        }
        self.pipeline = pipeline

        let preferences = AppPreferences.shared
        Task { [weak self] in
            do {
                try await pipeline.start(
                    sourceLanguage: preferences.realtimeSourceLanguage,
                    targetLanguage: preferences.realtimeTargetLanguage,
                    translatesText: preferences.realtimeTranslationProvider.performsTranslation
                )
            } catch {
                self?.finishBroadcast(error)
            }
        }
    }

    override func broadcastPaused() {
        RealtimeLog.log("broadcast", "extension paused relay=\(relayWriter != nil)")
        pipeline?.setPaused(true)
    }

    override func broadcastResumed() {
        RealtimeLog.log("broadcast", "extension resumed relay=\(relayWriter != nil)")
        pipeline?.setPaused(false)
    }

    override func broadcastFinished() {
        guard let finish = beginFinishing() else { return }
        // ReplayKit gives us a synchronous callback, not an unlimited background lifetime.
        // Keep it alive for a bounded drain; on timeout leave .stopping, never a false success.
        if finish.completion.waitForDrain(timeout: 5) {
            stopHeartbeat()
        } else {
            Task { [weak self] in
                await finish.task.value
                self?.stopHeartbeat()
            }
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        // Stop requests are polled by the 1 s heartbeat; decoding the shared state on every
        // sample buffer costs too much CPU and memory in the extension.
        guard sampleBufferType == .audioApp else { return }
        if let relayWriter {
            let level = relayWriter.append(sampleBuffer)
            reportRelayedBuffer(level: level)
            return
        }
        pipeline?.append(sampleBuffer)
    }

    /// Relay mode has no recognizer to report activity, so publish the count and level the host shows.
    private func reportRelayedBuffer(level: Float?) {
        guard let sessionID = completion?.sessionID else { return }
        relayedBufferCount += 1
        let count = relayedBufferCount
        guard count == 1 || count % Self.relayStateReportInterval == 0 else { return }
        stateStore.markProducerAlive(sessionID: sessionID, audioSampleCount: count, audioLevel: level)
        if count == 1 {
            stateStore.update(sessionID: sessionID) { state in
                if state.phase == .idle || state.phase == .waiting {
                    state.phase = .broadcasting
                }
            }
            RealtimeLog.log("broadcast", "relay first audio buffer session=\(sessionID)")
        }
    }

    /// Falls back to the local Apple pipeline once the host stops heartbeating (killed or suspended).
    /// The switch is one-way for the session; the pipeline's snapshots clear `usesHostRecognition`.
    private func checkHostRelay(sessionID: String) {
        guard relayWriter != nil else { return }
        let age = stateStore.hostHeartbeatAge(sessionID: sessionID)
        let now = Date()
        if now.timeIntervalSince(lastHostAgeLogAt) >= 5 {
            lastHostAgeLogAt = now
            RealtimeLog.log("broadcast", "relay host heartbeat age=\(Self.format(age)) buffers=\(relayedBufferCount)")
        }
        guard age == nil || age! > Self.hostHeartbeatTimeout else { return }
        let writer = pipelineLock.withLock { () -> RealtimeAudioRelayWriter? in
            let writer = _relayWriter
            _relayWriter = nil
            return writer
        }
        guard let writer else { return }
        writer.close()
        RealtimeLog.warn(
            "broadcast",
            "relay host lost age=\(Self.format(age)) buffers=\(relayedBufferCount); falling back to Apple Speech"
        )
        startLocalPipeline(sessionID: sessionID)
    }

    private static func format(_ age: TimeInterval?) -> String {
        age.map { String(format: "%.1fs", $0) } ?? "nil"
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.handleHeartbeat()
        }
        heartbeatLock.withLock {
            heartbeatTimer?.cancel()
            heartbeatTimer = timer
            timer.resume()
        }
    }

    private func stopHeartbeat() {
        heartbeatLock.withLock {
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
        }
    }

    private func handleHeartbeat() {
        guard let sessionID = completion?.sessionID else { return }
        // Liveness goes to a small key; the transcript snapshot is only written when it changes.
        if finishLock.withLock({ didFinishBroadcast }) {
            stateStore.markProducerAlive(sessionID: sessionID)
            return
        }
        guard !finishIfStopRequested() else { return }
        checkHostRelay(sessionID: sessionID)

        if hasReportedBroadcasting {
            stateStore.markProducerAlive(sessionID: sessionID)
        } else {
            hasReportedBroadcasting = true
            stateStore.update(sessionID: sessionID) { state in
                if state.phase == .idle || state.phase == .waiting {
                    state.phase = .broadcasting
                }
            }
        }
        _ = finishIfStopRequested()
    }

    @discardableResult
    private func finishIfStopRequested() -> Bool {
        guard let sessionID = completion?.sessionID,
              stateStore.isStopRequested(sessionID: sessionID)
        else { return false }
        finishBroadcast(RealtimeBroadcastError.stoppedByHost)
        return true
    }

    private func finishBroadcast(_ error: Error) {
        let stoppedByHost = RealtimeBroadcastError.isStoppedByHost(error)
        let message = RealtimeBroadcastError.message(for: error)
        guard let finish = beginFinishing(errorMessage: stoppedByHost ? nil : message),
              finish.isFirst
        else { return }
        let replayKitError = RealtimeBroadcastError.replayKitError(from: error)
        Task { [weak self] in
            await finish.task.value
            self?.stopHeartbeat()
            DispatchQueue.main.async { [weak self] in
                self?.finishBroadcastWithError(replayKitError)
            }
        }
    }

    private func resetFinishState() {
        finishLock.lock()
        didFinishBroadcast = false
        finishLock.unlock()
    }

    private func beginFinishing(
        errorMessage: String? = nil
    ) -> (completion: RealtimeBroadcastCompletion, task: Task<Void, Never>, isFirst: Bool)? {
        finishLock.lock()
        defer { finishLock.unlock() }
        guard let completion else { return nil }
        let isFirst = !didFinishBroadcast
        didFinishBroadcast = true
        let pipeline = pipeline
        self.pipeline = nil
        let relayWriter = relayWriter
        self.relayWriter = nil
        relayWriter?.close()
        let task = completion.finish(errorMessage: errorMessage) {
            await pipeline?.stop()
        }
        return (completion, task, isFirst)
    }
}

private enum RealtimeBroadcastError: LocalizedError {
    case stoppedByHost

    static let domain = "com.zanderwang.AITranslator.BroadcastUpload"

    var errorDescription: String? {
        switch self {
        case .stoppedByHost:
            return """
            TLingo requested this iPhone Audio broadcast to stop. \
            Wait until TLingo shows Stopped before starting again.
            """
        }
    }

    static func isStoppedByHost(_ error: Error) -> Bool {
        guard let error = error as? RealtimeBroadcastError else { return false }
        return error == .stoppedByHost
    }

    static func message(for error: Error) -> String {
        if let error = error as? RealtimeBroadcastError,
           let description = error.errorDescription,
           !description.isEmpty
        {
            return description
        }
        return RealtimeSessionStore.realtimeErrorDescription(for: error)
    }

    static func replayKitError(from error: Error) -> Error {
        let message = message(for: error)
        return NSError(
            domain: domain,
            code: isStoppedByHost(error) ? 1 : 2,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                NSLocalizedFailureReasonErrorKey: message,
                NSLocalizedRecoverySuggestionErrorKey: isStoppedByHost(error)
                    ? "Wait until TLingo shows Stopped before starting iPhone Audio again."
                    : "Open TLingo and check the Realtime alert for the last broadcast phase and underlying error code.",
            ]
        )
    }
}
