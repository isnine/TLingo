//
//  RealtimeAudioHistoryRecorderTests.swift
//  ShareCoreTests
//

#if os(macOS) || os(iOS)
    import AVFoundation
    import Foundation
    import Testing

    @testable import ShareCore

    @Suite("RealtimeAudioHistoryRecorder")
    struct RealtimeAudioHistoryRecorderTests {
        @Test("Snapshots only completed readable audio segments")
        func snapshotsOnlyCompletedReadableAudioSegments() throws {
            let requestID = UUID()
            let recorder = RealtimeAudioHistoryRecorder(segmentDuration: 0.1)
            recorder.start(requestID: requestID, source: .macAudio)
            defer {
                if let directoryURL = RealtimeHistoryAudioStorage.directoryURL(for: "\(requestID.uuidString)-macAudio") {
                    try? FileManager.default.removeItem(at: directoryURL)
                }
            }

            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400))
            buffer.frameLength = 2400
            if let channel = buffer.floatChannelData?.pointee {
                for index in 0 ..< Int(buffer.frameLength) {
                    channel[index] = sin(Float(index) / 12)
                }
            }

            #expect(recorder.snapshot() == nil)
            #expect(recorder.append(buffer))

            let recording = try #require(recorder.snapshot())
            #expect(recording.source == .macAudio)
            #expect(recording.directoryName == "\(requestID.uuidString)-macAudio")
            #expect(recording.segments.count == 1)
            let segment = recording.segments[0]
            let url = try #require(RealtimeHistoryAudioStorage.fileURL(for: segment))
            #expect(FileManager.default.fileExists(atPath: url.path))
            let audioFile = try AVAudioFile(forReading: url)
            #expect(audioFile.length > 0)
        }

        @Test("Uses separate directories per audio source")
        func usesSeparateDirectoriesPerAudioSource() throws {
            let requestID = UUID()
            let macRecorder = RealtimeAudioHistoryRecorder(segmentDuration: 0.1)
            let microphoneRecorder = RealtimeAudioHistoryRecorder(segmentDuration: 0.1)
            macRecorder.start(requestID: requestID, source: .macAudio)
            microphoneRecorder.start(requestID: requestID, source: .microphone)
            defer {
                for suffix in ["macAudio", "microphone"] {
                    if let directoryURL = RealtimeHistoryAudioStorage.directoryURL(for: "\(requestID.uuidString)-\(suffix)") {
                        try? FileManager.default.removeItem(at: directoryURL)
                    }
                }
            }

            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400))
            buffer.frameLength = 2400

            #expect(macRecorder.append(buffer))
            #expect(microphoneRecorder.append(buffer))
            let macRecording = try #require(macRecorder.snapshot())
            let microphoneRecording = try #require(microphoneRecorder.snapshot())

            #expect(macRecording.directoryName == "\(requestID.uuidString)-macAudio")
            #expect(microphoneRecording.directoryName == "\(requestID.uuidString)-microphone")
        }
    }
#endif
