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
    private var completion: RealtimeBroadcastCompletion?

    /// Read on ReplayKit's sample queue and cleared from heartbeat and failure callbacks.
    private var pipeline: RealtimeLocalSpeechTranslationPipeline? {
        get { pipelineLock.withLock { _pipeline } }
        set { pipelineLock.withLock { _pipeline = newValue } }
    }

    private var didFinishBroadcast = false

    override func broadcastStarted(withSetupInfo _: [String: NSObject]?) {
        resetFinishState()
        let previous = stateStore.load()
        let sessionID: String
        if let previous, previous.phase != .stopped, previous.phase != .failed {
            sessionID = previous.sessionID
        } else {
            sessionID = UUID().uuidString
            stateStore.reset(sessionID: sessionID, phase: .waiting)
        }
        completion = RealtimeBroadcastCompletion(store: stateStore, sessionID: sessionID)
        let pipeline = RealtimeLocalSpeechTranslationPipeline(stateStore: stateStore, sessionID: sessionID)
        pipeline.onFailure = { [weak self] error in
            self?.finishBroadcast(error)
        }
        self.pipeline = pipeline
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
        }
        startHeartbeat()

        let preferences = AppPreferences.shared
        Task { [weak self] in
            do {
                try await pipeline.start(
                    sourceLanguage: preferences.realtimeSourceLanguage,
                    targetLanguage: preferences.realtimeTargetLanguage
                )
            } catch {
                self?.finishBroadcast(error)
            }
        }
    }

    override func broadcastPaused() {
        pipeline?.setPaused(true)
    }

    override func broadcastResumed() {
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
        if sampleBufferType == .audioApp {
            pipeline?.append(sampleBuffer)
        }
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
        if finishLock.withLock({ didFinishBroadcast }) {
            stateStore.update(sessionID: sessionID) { _ in }
            return
        }
        guard !finishIfStopRequested() else { return }

        stateStore.update(sessionID: sessionID) { state in
            if state.phase == .idle || state.phase == .waiting {
                state.phase = .broadcasting
            }
        }
        _ = finishIfStopRequested()
    }

    @discardableResult
    private func finishIfStopRequested() -> Bool {
        guard let state = stateStore.load(),
              state.sessionID == completion?.sessionID, state.stopRequested
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
