#if os(macOS) || os(iOS)
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
        private static let audioLevelReportInterval = 8

        weak var delegate: RealtimeMicrophoneAudioCaptureDelegate?

        private let sampleQueue = DispatchQueue(label: "TLingo.RealtimeMicrophoneAudioCapture.sampleQueue")
        #if os(macOS)
            private var session: AVCaptureSession?
            private var output: AVCaptureAudioDataOutput?
            private var sessionObservers: [NSObjectProtocol] = []
        #elseif os(iOS)
            private let audioEngine = AVAudioEngine()
            private var converter: AVAudioConverter?
            private var targetFormat: AVAudioFormat?
            private var conversionFailureCount = 0
        #endif
        private var audioSampleCount = 0

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
                session.startRunning()
            #elseif os(iOS)
                try startAudioEngine(sampleRate: sampleRate)
            #endif
        }

        func stop() {
            #if os(macOS)
                removeSessionObservers()
                output?.setSampleBufferDelegate(nil, queue: nil)
                if let session, session.isRunning {
                    session.stopRunning()
                }
                output = nil
                session = nil
            #elseif os(iOS)
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
                converter = nil
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
            private func configureAudioSession(allowsPlayback: Bool) throws {
                let audioSession = AVAudioSession.sharedInstance()
                if allowsPlayback {
                    try audioSession.setCategory(
                        .playAndRecord,
                        mode: .measurement,
                        options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
                    )
                } else {
                    try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
                }
                try? audioSession.setPreferredSampleRate(48000)
                try? audioSession.setPreferredInputNumberOfChannels(1)
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            }

            private func startAudioEngine(sampleRate: Int) throws {
                let inputNode = audioEngine.inputNode
                guard let inputFormat = validInputFormat(for: inputNode) else {
                    throw RealtimeCaptureError.microphoneUnavailable
                }
                guard let targetFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: Double(sampleRate),
                    channels: 1,
                    interleaved: false
                )
                else {
                    throw RealtimeCaptureError.microphoneUnavailable
                }

                self.targetFormat = targetFormat
                converter = nil
                conversionFailureCount = 0
                audioSampleCount = 0
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                    self?.handleInputBuffer(buffer)
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

            private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
                guard let convertedBuffer = convertedPCMBuffer(from: buffer) else {
                    // Dropped audio never reaches the recognizer, so speech silently goes missing.
                    conversionFailureCount += 1
                    if conversionFailureCount == 1 || conversionFailureCount % 50 == 0 {
                        RealtimeLog.warn(
                            "audio",
                            "buffer conversion failed count=\(conversionFailureCount) input=\(buffer.format.description)"
                        )
                    }
                    return
                }

                audioSampleCount += 1
                delegate?.realtimeMicrophoneAudioCapture(self, didOutput: convertedBuffer)
                if audioSampleCount == 1 || audioSampleCount % Self.audioLevelReportInterval == 0 {
                    delegate?.realtimeMicrophoneAudioCapture(
                        self,
                        didReceiveAudioSampleCount: audioSampleCount,
                        level: realtimeAudioLevel(from: convertedBuffer)
                    )
                }
            }

            private func convertedPCMBuffer(from inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
                guard let targetFormat else { return nil }
                if converter?.inputFormat != inputBuffer.format {
                    converter = AVAudioConverter(from: inputBuffer.format, to: targetFormat)
                }
                guard let converter else { return nil }
                let sampleRateRatio = targetFormat.sampleRate / inputBuffer.format.sampleRate
                let frameCapacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * sampleRateRatio).rounded(.up)) + 1
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                    return nil
                }

                var didProvideInput = false
                let inputBlock: AVAudioConverterInputBlock = { _, outputStatus in
                    if didProvideInput {
                        outputStatus.pointee = .noDataNow
                        return nil
                    }

                    didProvideInput = true
                    outputStatus.pointee = .haveData
                    return inputBuffer
                }

                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
                guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else {
                    return nil
                }
                return outputBuffer
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
#endif
