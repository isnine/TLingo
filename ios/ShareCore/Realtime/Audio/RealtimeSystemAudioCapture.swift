#if os(macOS)
    import AVFoundation
    import CoreGraphics
    import ScreenCaptureKit

    protocol RealtimeSystemAudioCaptureDelegate: AnyObject {
        func realtimeSystemAudioCapture(_ capture: RealtimeSystemAudioCapture, didOutput sampleBuffer: CMSampleBuffer)
        func realtimeSystemAudioCapture(
            _ capture: RealtimeSystemAudioCapture,
            didReceiveAudioSampleCount count: Int,
            level: Float?
        )
        func realtimeSystemAudioCapture(_ capture: RealtimeSystemAudioCapture, didFail error: Error)
    }

    final class RealtimeSystemAudioCapture: NSObject, @unchecked Sendable {
        private static let audioLevelReportInterval = 8

        weak var delegate: RealtimeSystemAudioCaptureDelegate?

        private var stream: SCStream?
        private var audioSampleCount = 0
        private let sampleQueue = DispatchQueue(label: "TLingo.RealtimeSystemAudioCapture.sampleQueue")

        @MainActor
        func requestScreenRecordingAccess() throws {
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                throw RealtimeCaptureError.screenRecordingNotGranted
            }
        }

        @MainActor
        func start(sampleRate: Int = 16000) async throws {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let display = content.displays.first else {
                throw RealtimeCaptureError.noDisplay
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = sampleRate
            configuration.channelCount = 1

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            audioSampleCount = 0
            self.stream = stream
        }

        func stop() async {
            guard let stream else { return }
            try? stream.removeStreamOutput(self, type: .screen)
            try? stream.removeStreamOutput(self, type: .audio)
            try? await stream.stopCapture()
            self.stream = nil
        }
    }

    extension RealtimeSystemAudioCapture: SCStreamDelegate, SCStreamOutput {
        func stream(_: SCStream, didStopWithError _: Error) {
            delegate?.realtimeSystemAudioCapture(self, didFail: RealtimeCaptureError.systemAudioCaptureStopped)
        }

        func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio, sampleBuffer.isValid else { return }
            audioSampleCount += 1
            delegate?.realtimeSystemAudioCapture(self, didOutput: sampleBuffer)
            if audioSampleCount == 1 || audioSampleCount % Self.audioLevelReportInterval == 0 {
                delegate?.realtimeSystemAudioCapture(
                    self,
                    didReceiveAudioSampleCount: audioSampleCount,
                    level: realtimeAudioLevel(from: sampleBuffer)
                )
            }
        }
    }
#endif
