import AVFoundation

protocol RealtimeMicrophoneAudioCaptureDelegate: AnyObject {
    func realtimeMicrophoneAudioCapture(_ capture: RealtimeMicrophoneAudioCapture, didOutput sampleBuffer: CMSampleBuffer)
    func realtimeMicrophoneAudioCapture(_ capture: RealtimeMicrophoneAudioCapture, didOutput pcmBuffer: AVAudioPCMBuffer)
    func realtimeMicrophoneAudioCapture(
        _ capture: RealtimeMicrophoneAudioCapture,
        didReceiveAudioSampleCount count: Int,
        level: Float?
    )
    func realtimeMicrophoneAudioCapture(_ capture: RealtimeMicrophoneAudioCapture, didFail error: Error)
}

final class RealtimeMicrophoneAudioCapture: NSObject, @unchecked Sendable {
    #if os(iOS)
        /// 1024-frame buffers at 48 kHz: ~43 ms, fast enough for the listening indicator.
        private static let audioLevelReportInterval = 2
    #else
        private static let audioLevelReportInterval = 8
    #endif

    weak var delegate: RealtimeMicrophoneAudioCaptureDelegate?

    private let sampleQueue = DispatchQueue(label: "TLingo.RealtimeMicrophoneAudioCapture.sampleQueue")
    #if os(macOS)
        /// `startRunning` and `stopRunning` block until the device settles, so keep them off main.
        private let sessionQueue = DispatchQueue(label: "TLingo.RealtimeMicrophoneAudioCapture.sessionQueue")
    #endif
    #if os(macOS)
        private var session: AVCaptureSession?
        private var output: AVCaptureAudioDataOutput?
        private var sessionObservers: [NSObjectProtocol] = []
        private var audioSampleCount = 0
    #elseif os(iOS)
        /// Conversion state for one installed tap. Only the audio thread touches it,
        /// so start, stop and restart on the main thread never race the tap.
        private final class TapState: @unchecked Sendable {
            let converter: RealtimePCMBufferConverter
            var conversionFailureCount = 0
            var audioSampleCount = 0

            init(targetFormat: AVAudioFormat) {
                converter = RealtimePCMBufferConverter(targetFormat: targetFormat)
            }
        }

        /// Replaced after a media services reset, which invalidates every audio object.
        private var audioEngine = AVAudioEngine()
        private var targetFormat: AVAudioFormat?
        private var engineSampleRate = 16000
        private var allowsPlayback = false
        private var configurationChangeObserver: NSObjectProtocol?
        private var mediaServicesResetObserver: NSObjectProtocol?
        private var interruptionObserver: NSObjectProtocol?
        /// The engine cannot restart during an interruption; the session store resumes it afterwards.
        private var isInterrupted = false
    #endif

    @MainActor
    func start(sampleRate: Int = 16000, allowsPlayback: Bool = false) async throws {
        guard await requestMicrophoneAccess() else {
            throw RealtimeCaptureError.microphoneNotGranted
        }

        stop()
        #if os(iOS)
            try configureAudioSession(allowsPlayback: allowsPlayback)
        #endif

        #if os(macOS)
            guard let device = AVCaptureDevice.default(for: .audio) else {
                throw RealtimeCaptureError.microphoneUnavailable
            }

            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            output.setSampleBufferDelegate(self, queue: sampleQueue)

            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                throw RealtimeCaptureError.microphoneUnavailable
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()

            audioSampleCount = 0
            self.output = output
            self.session = session
            registerSessionObservers(for: session)
            await withCheckedContinuation { continuation in
                sessionQueue.async {
                    session.startRunning()
                    continuation.resume()
                }
            }
        #elseif os(iOS)
            engineSampleRate = sampleRate
            self.allowsPlayback = allowsPlayback
            try startAudioEngine(sampleRate: sampleRate)
            observeEngineConfigurationChanges()
        #endif
    }

    func stop() {
        #if os(macOS)
            removeSessionObservers()
            output?.setSampleBufferDelegate(nil, queue: nil)
            if let session {
                sessionQueue.async {
                    if session.isRunning {
                        session.stopRunning()
                    }
                }
            }
            output = nil
            session = nil
        #elseif os(iOS)
            if let configurationChangeObserver {
                NotificationCenter.default.removeObserver(configurationChangeObserver)
                self.configurationChangeObserver = nil
            }
            if let mediaServicesResetObserver {
                NotificationCenter.default.removeObserver(mediaServicesResetObserver)
                self.mediaServicesResetObserver = nil
            }
            if let interruptionObserver {
                NotificationCenter.default.removeObserver(interruptionObserver)
                self.interruptionObserver = nil
            }
            isInterrupted = false
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            targetFormat = nil
        #endif
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    #if os(macOS)
        private func registerSessionObservers(for session: AVCaptureSession) {
            removeSessionObservers()
            sessionObservers = [
                NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.runtimeErrorNotification,
                    object: session,
                    queue: nil
                ) { [weak self] notification in
                    self?.handleSessionRuntimeError(notification)
                },
                NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.wasInterruptedNotification,
                    object: session,
                    queue: nil
                ) { [weak self] _ in
                    guard let self else { return }
                    delegate?.realtimeMicrophoneAudioCapture(self, didFail: RealtimeCaptureError.microphoneCaptureInterrupted)
                },
            ]
        }

        private func removeSessionObservers() {
            for observer in sessionObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            sessionObservers.removeAll()
        }

        private func handleSessionRuntimeError(_ notification: Notification) {
            let nsError = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let reason = nsError.map { "\($0.localizedDescription) Error: \($0.domain) \($0.code)" }
            delegate?.realtimeMicrophoneAudioCapture(
                self,
                didFail: RealtimeCaptureError.microphoneCaptureRuntimeError(reason)
            )
        }
    #endif

    @MainActor
    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    #if os(iOS)
        /// `.measurement` disables the system's gain control, so distant speech arrived far too quiet.
        /// Voice processing is left off: its noise suppression erased faint or distant speech
        /// entirely, and capture never plays audio, so its echo cancellation is not needed.
        private func configureAudioSession(allowsPlayback: Bool) throws {
            let audioSession = AVAudioSession.sharedInstance()
            let options: AVAudioSession.CategoryOptions = allowsPlayback
                ? [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
                : [.duckOthers, .allowBluetoothHFP]
            try audioSession.setCategory(.playAndRecord, mode: .default, options: options)
            try? audioSession.setPreferredSampleRate(48000)
            try? audioSession.setPreferredInputNumberOfChannels(1)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        }

        private func startAudioEngine(sampleRate: Int) throws {
            let inputNode = audioEngine.inputNode
            guard let inputFormat = validInputFormat(for: inputNode), let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: false
            )
            else {
                throw RealtimeCaptureError.microphoneUnavailable
            }

            self.targetFormat = targetFormat
            let tapState = TapState(targetFormat: targetFormat)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.handleInputBuffer(buffer, state: tapState)
            }
            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                RealtimeLog.warn(
                    "audio",
                    "microphone engine start failed error=\(String(describing: error)) input=\(inputFormat.description)"
                )
                inputNode.removeTap(onBus: 0)
                throw RealtimeCaptureError.microphoneUnavailable
            }
            RealtimeLog.log(
                "audio",
                """
                microphone started input=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch \
                target=\(sampleRate)Hz route=\(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portType.rawValue))
                """
            )
        }

        /// Restarts capture an audio interruption stopped. Does nothing while the engine still runs.
        @MainActor
        func restartIfStopped() throws {
            guard targetFormat != nil, !audioEngine.isRunning else { return }
            RealtimeLog.log("audio", "microphone engine stopped; restarting")
            audioEngine.inputNode.removeTap(onBus: 0)
            try configureAudioSession(allowsPlayback: allowsPlayback)
            try startAudioEngine(sampleRate: engineSampleRate)
        }

        /// Route changes (AirPods, wired headset) stop the engine and leave the tap silent.
        private func observeEngineConfigurationChanges() {
            configurationChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: audioEngine,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restartAudioEngineAfterConfigurationChange()
                }
            }
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
                let isBegan = AVAudioSession.InterruptionType(rawValue: typeValue) == .began
                MainActor.assumeIsolated {
                    self?.isInterrupted = isBegan
                }
            }
            // Apple asks apps to rebuild audio objects after a reset and to restart only on user action.
            mediaServicesResetObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.targetFormat != nil else { return }
                    RealtimeLog.warn("audio", "media services were reset; ending microphone capture")
                    self.stop()
                    self.audioEngine = AVAudioEngine()
                    self.delegate?.realtimeMicrophoneAudioCapture(
                        self,
                        didFail: RealtimeCaptureError.microphoneCaptureInterrupted
                    )
                }
            }
        }

        @MainActor
        private func restartAudioEngineAfterConfigurationChange() {
            guard targetFormat != nil, !isInterrupted else { return }
            RealtimeLog.log("audio", "microphone engine configuration changed; restarting")
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            do {
                try startAudioEngine(sampleRate: engineSampleRate)
            } catch {
                delegate?.realtimeMicrophoneAudioCapture(self, didFail: error)
            }
        }

        private func validInputFormat(for inputNode: AVAudioInputNode) -> AVAudioFormat? {
            let nodeFormat = inputNode.outputFormat(forBus: 0)
            guard nodeFormat.sampleRate > 0, nodeFormat.channelCount > 0 else {
                RealtimeLog.warn("audio", "microphone input node has invalid format node=\(nodeFormat.description)")
                return nil
            }
            guard AVAudioSession.sharedInstance().inputNumberOfChannels > 0 else {
                RealtimeLog.warn("audio", "microphone session has no input channels node=\(nodeFormat.description)")
                return nil
            }
            return nodeFormat
        }

        private func handleInputBuffer(_ buffer: AVAudioPCMBuffer, state: TapState) {
            guard let convertedBuffer = state.converter.pcmBuffer(from: buffer) else {
                // Dropped audio never reaches the recognizer, so speech silently goes missing.
                state.conversionFailureCount += 1
                if state.conversionFailureCount == 1 || state.conversionFailureCount % 50 == 0 {
                    RealtimeLog.warn(
                        "audio",
                        "buffer conversion failed count=\(state.conversionFailureCount) input=\(buffer.format.description)"
                    )
                }
                return
            }

            state.audioSampleCount += 1
            delegate?.realtimeMicrophoneAudioCapture(self, didOutput: convertedBuffer)
            if state.audioSampleCount == 1 || state.audioSampleCount % Self.audioLevelReportInterval == 0 {
                delegate?.realtimeMicrophoneAudioCapture(
                    self,
                    didReceiveAudioSampleCount: state.audioSampleCount,
                    level: realtimeAudioLevel(from: convertedBuffer)
                )
            }
        }
    #endif
}

extension RealtimeMicrophoneAudioCaptureDelegate {
    func realtimeMicrophoneAudioCapture(_: RealtimeMicrophoneAudioCapture, didOutput _: CMSampleBuffer) {}
    func realtimeMicrophoneAudioCapture(_: RealtimeMicrophoneAudioCapture, didOutput _: AVAudioPCMBuffer) {}
    func realtimeMicrophoneAudioCapture(_: RealtimeMicrophoneAudioCapture, didFail _: Error) {}
}

#if os(macOS)
    extension RealtimeMicrophoneAudioCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
        func captureOutput(
            _: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from _: AVCaptureConnection
        ) {
            guard sampleBuffer.isValid else { return }

            audioSampleCount += 1
            delegate?.realtimeMicrophoneAudioCapture(self, didOutput: sampleBuffer)
            if audioSampleCount == 1 || audioSampleCount % Self.audioLevelReportInterval == 0 {
                delegate?.realtimeMicrophoneAudioCapture(
                    self,
                    didReceiveAudioSampleCount: audioSampleCount,
                    level: realtimeAudioLevel(from: sampleBuffer)
                )
            }
        }
    }
#endif
