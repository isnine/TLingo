import CoreMedia
import Foundation
import ReplayKit
import ShareCore

final class SampleHandler: RPBroadcastSampleHandler {
    private let stateStore = RealtimeBroadcastStateStore() ?? RealtimeBroadcastStateStore(defaults: .standard)
    private let heartbeatQueue = DispatchQueue(label: "com.zanderwang.AITranslator.BroadcastUpload.heartbeat")
    private let finishLock = NSLock()
    private var heartbeatTimer: DispatchSourceTimer?
    private var pipeline: RealtimeLocalSpeechTranslationPipeline?
    private var didFinishBroadcast = false

    override func broadcastStarted(withSetupInfo _: [String: NSObject]?) {
        resetFinishState()
        // A fresh broadcastStarted is the authoritative "session is live" signal. Always start from a
        // clean state and clear any stale stopRequested left over from a previous session. Finishing the
        // broadcast here — before the session is fully established — makes iOS discard our error and show
        // RPRecordingError "Attempting to start an invalid broadcast session". A genuine stop request is
        // instead handled by finishIfStopRequested() from the heartbeat/sample callbacks, which fire only
        // after the session is valid, so finishBroadcastWithError surfaces our own message.
        let sessionID = stateStore.load()?.sessionID ?? UUID().uuidString
        let pipeline = RealtimeLocalSpeechTranslationPipeline(stateStore: stateStore, sessionID: sessionID)
        pipeline.onFailure = { [weak self] error in
            self?.finishBroadcast(error)
        }
        self.pipeline = pipeline
        stateStore.update(synchronize: true) { state in
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
        if let pipeline {
            pipeline.setPaused(true)
        } else {
            stateStore.update { state in
                state.phase = .paused
            }
        }
    }

    override func broadcastResumed() {
        if let pipeline {
            pipeline.setPaused(false)
        } else {
            stateStore.update { state in
                state.phase = .broadcasting
            }
        }
    }

    override func broadcastFinished() {
        // The system can end the broadcast (Control Center / status bar) without routing through
        // finishBroadcast. Write a clean terminal state so a leftover stopRequested/phase can't make
        // the next broadcastStarted self-terminate with an "invalid session" error.
        guard markBroadcastFinishing() else {
            stopHeartbeat()
            writeTerminalBroadcastState()
            if let pipeline {
                Task {
                    await pipeline.stop()
                }
            }
            pipeline = nil
            return
        }
        stopHeartbeat()
        writeTerminalBroadcastState()
        let pipeline = pipeline
        self.pipeline = nil
        Task {
            await pipeline?.stop()
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard !finishIfStopRequested() else { return }

        switch sampleBufferType {
        case .audioApp:
            pipeline?.append(sampleBuffer)
            _ = finishIfStopRequested()
        case .video, .audioMic:
            _ = finishIfStopRequested()
        @unknown default:
            break
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.handleHeartbeat()
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func handleHeartbeat() {
        guard !finishIfStopRequested() else { return }

        stateStore.update { state in
            if state.phase == .idle || state.phase == .waiting {
                state.phase = .broadcasting
            }
        }
        _ = finishIfStopRequested()
    }

    @discardableResult
    private func finishIfStopRequested() -> Bool {
        guard stateStore.load()?.stopRequested == true else { return false }
        finishBroadcast(RealtimeBroadcastError.stoppedByHost)
        return true
    }

    private func finishBroadcast(_ error: Error) {
        guard markBroadcastFinishing() else { return }

        let stoppedByHost = RealtimeBroadcastError.isStoppedByHost(error)
        let message = RealtimeBroadcastError.message(for: error)
        stopHeartbeat()
        let pipeline = pipeline
        self.pipeline = nil
        let replayKitError = RealtimeBroadcastError.replayKitError(from: error)
        Task { [weak self] in
            await pipeline?.stop()
            self?.stateStore.update(synchronize: true) { state in
                state.phase = stoppedByHost ? .stopped : .failed
                state.errorMessage = stoppedByHost ? nil : message
                state.stopRequested = false
            }
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

    private func writeTerminalBroadcastState() {
        stateStore.update(synchronize: true) { state in
            state.markBroadcastFinished()
        }
    }

    private func markBroadcastFinishing() -> Bool {
        finishLock.lock()
        defer { finishLock.unlock() }
        guard !didFinishBroadcast else { return false }
        didFinishBroadcast = true
        return true
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
