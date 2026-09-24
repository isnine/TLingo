//
//  RealtimeHistoryExportDocumentTests.swift
//  ShareCoreTests
//

import AVFoundation
import Foundation
import Testing

@testable import ShareCore

@Suite("RealtimeHistoryExportDocument")
struct RealtimeHistoryExportDocumentTests {
    @Test("Exports markdown, merged audio, and LRC files per source")
    func exportsMarkdownMergedAudioAndLRCFiles() throws {
        let fixture = try makeSessionWithAudio()
        defer { fixture.cleanup() }

        let wrapper = try RealtimeHistoryExportDocument(session: fixture.session).makeFileWrapper()
        let rootFiles = try #require(wrapper.fileWrappers)
        let transcript = try #require(rootFiles["transcript.md"]?.regularFileContents)
        let markdown = try #require(String(data: transcript, encoding: .utf8))
        let audioFiles = try #require(rootFiles["audio"]?.fileWrappers)
        let macAudio = try #require(audioFiles["mac-audio.m4a"]?.regularFileContents)
        let microphoneAudio = try #require(audioFiles["microphone.m4a"]?.regularFileContents)
        let macLRCData = try #require(audioFiles["mac-audio.lrc"]?.regularFileContents)
        let microphoneLRCData = try #require(audioFiles["microphone.lrc"]?.regularFileContents)
        let macLRC = try #require(String(data: macLRCData, encoding: .utf8))
        let microphoneLRC = try #require(String(data: microphoneLRCData, encoding: .utf8))
        let macFrameCount = try audioFrameCount(macAudio)
        let microphoneFrameCount = try audioFrameCount(microphoneAudio)

        #expect(audioFiles.count == 4)
        #expect(audioFiles["mac-audio"] == nil)
        #expect(audioFiles["microphone"] == nil)
        #expect(macFrameCount > microphoneFrameCount)
        #expect(microphoneFrameCount > 0)
        #expect(macLRC == "[00:00.100]Hello.\nHola.\n\n[00:00.350]Follow up.\nSeguimiento.\n")
        #expect(microphoneLRC == "[00:00.050]Mic hello.\nMic hola.\n")
        #expect(markdown.contains("Hello."))
        #expect(markdown.contains("Hola."))
        #expect(markdown.contains("Follow up."))
        #expect(markdown.contains("Seguimiento."))
        #expect(!markdown.contains("Bilingual Transcript"))
        #expect(!markdown.contains("## Audio"))
        #expect(!markdown.contains("## Conversation"))
        #expect(!markdown.contains("Request ID"))
    }

    @Test("Fails when an audio file is missing")
    func failsWhenAudioFileIsMissing() throws {
        let session = RealtimeHistorySession(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 112),
            duration: 12,
            inputSource: RealtimeHistoryAudioSource.macAudio.title,
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: "apple-translate",
            modelDisplayName: "Apple Translate",
            segments: [
                RealtimeHistorySegment(offset: 0.1, sourceText: "Hello.", translatedText: "Hola."),
                RealtimeHistorySegment(offset: 0.35, sourceText: "Follow up.", translatedText: "Seguimiento."),
            ],
            audioRecordings: [
                RealtimeHistoryAudioRecording(
                    source: .macAudio,
                    directoryName: "missing",
                    sampleRate: 16000,
                    channelCount: 1,
                    segments: [
                        RealtimeHistoryAudioSegment(
                            relativePath: "missing/segment.m4a",
                            offset: 0,
                            duration: 3,
                            byteCount: 3
                        ),
                    ]
                ),
            ]
        )

        do {
            _ = try RealtimeHistoryExportDocument(session: session).makeFileWrapper()
            Issue.record("Expected missing audio file error")
        } catch let error as RealtimeHistoryExportError {
            #expect(error == .missingAudioFile("missing/segment.m4a"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Exports one LRC file for each realtime track")
    func exportsTrackLRCFiles() throws {
        let first = RealtimeHistoryTrack(
            recognitionModelID: "apple-speech",
            recognitionModelDisplayName: "Apple Speech",
            translationProviderID: "apple_translator",
            translationProviderDisplayName: "Apple Translator",
            segments: [
                RealtimeHistoryTrackSegment(
                    offset: 1,
                    duration: 2,
                    speakerID: "S01",
                    sourceText: "Hello.",
                    translatedText: "Hola.",
                    relation: .paired
                ),
            ]
        )
        let second = RealtimeHistoryTrack(
            recognitionModelID: "qwen3-asr-int8",
            recognitionModelDisplayName: "Qwen3 ASR",
            translationProviderID: "apple_translation_realtime",
            translationProviderDisplayName: "Apple Translation Realtime",
            segments: [
                RealtimeHistoryTrackSegment(
                    offset: 2,
                    sourceText: "Source stream.",
                    relation: .sourceOnly
                ),
                RealtimeHistoryTrackSegment(
                    offset: 2.5,
                    translatedText: "Translation stream.",
                    relation: .translationOnly
                ),
            ]
        )
        let session = RealtimeHistorySession(
            requestID: UUID(),
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 110),
            duration: 10,
            inputSource: "Mac Audio",
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: first.translationProviderID,
            modelDisplayName: first.translationProviderDisplayName,
            segments: first.legacySegments,
            tracks: [first, second],
            primaryTrackID: first.id
        )

        let wrapper = try RealtimeHistoryExportDocument(session: session).makeFileWrapper()
        let rootFiles = try #require(wrapper.fileWrappers)
        let trackFiles = try #require(rootFiles["tracks"]?.fileWrappers)
        let markdownData = try #require(rootFiles["transcript.md"]?.regularFileContents)
        let markdown = try #require(String(data: markdownData, encoding: .utf8))

        #expect(trackFiles.count == 2)
        #expect(trackFiles.keys.contains { $0.contains("apple-speech-apple-translator") })
        #expect(trackFiles.keys.contains { $0.contains("qwen3-asr-azure-gpt-realtime-translator") })
        #expect(markdown.contains("## Mac Audio · Apple Speech → Apple Translator"))
        #expect(markdown.contains("## Mac Audio · Qwen3 ASR → Apple Translation Realtime"))
        #expect(markdown.contains("Speaker S01"))
        let firstLRCData = try #require(trackFiles.values.first {
            String(data: $0.regularFileContents ?? Data(), encoding: .utf8)?.contains("Speaker S01") == true
        }?.regularFileContents)
        #expect(String(data: firstLRCData, encoding: .utf8)?.contains("[Speaker S01] Hello.") == true)
    }

    private func makeSessionWithAudio() throws -> (session: RealtimeHistorySession, cleanup: () -> Void) {
        let requestID = UUID()
        let macDirectory = "\(requestID.uuidString)-macAudio"
        let microphoneDirectory = "\(requestID.uuidString)-microphone"
        let macURL = try #require(RealtimeHistoryAudioStorage.directoryURL(for: macDirectory))
        let microphoneURL = try #require(RealtimeHistoryAudioStorage.directoryURL(for: microphoneDirectory))
        let macSegment1URL = macURL.appendingPathComponent("segment-0001.m4a")
        let macSegment2URL = macURL.appendingPathComponent("segment-0002.m4a")
        let microphoneSegmentURL = microphoneURL.appendingPathComponent("segment-0001.m4a")
        try FileManager.default.createDirectory(at: macURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: microphoneURL, withIntermediateDirectories: true)
        try writeAudioSegment(to: macSegment1URL, frameCount: 4000)
        try writeAudioSegment(to: macSegment2URL, frameCount: 4000)
        try writeAudioSegment(to: microphoneSegmentURL, frameCount: 4000)

        let session = RealtimeHistorySession(
            requestID: requestID,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 112),
            duration: 12,
            inputSource: RealtimeHistoryAudioSource.macAudio.title,
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: "apple-translate",
            modelDisplayName: "Apple Translate",
            segments: [
                RealtimeHistorySegment(offset: 0.1, sourceText: "Hello.", translatedText: "Hola."),
                RealtimeHistorySegment(offset: 0.35, sourceText: "Follow up.", translatedText: "Seguimiento."),
            ],
            audioRecordings: [
                RealtimeHistoryAudioRecording(
                    source: .macAudio,
                    directoryName: macDirectory,
                    sampleRate: 16000,
                    channelCount: 1,
                    segments: [
                        RealtimeHistoryAudioSegment(
                            relativePath: "\(macDirectory)/segment-0001.m4a",
                            offset: 0,
                            duration: 0.25,
                            byteCount: byteCount(at: macSegment1URL)
                        ),
                        RealtimeHistoryAudioSegment(
                            relativePath: "\(macDirectory)/segment-0002.m4a",
                            offset: 0.25,
                            duration: 0.25,
                            byteCount: byteCount(at: macSegment2URL)
                        ),
                    ]
                ),
                RealtimeHistoryAudioRecording(
                    source: .microphone,
                    directoryName: microphoneDirectory,
                    sampleRate: 16000,
                    channelCount: 1,
                    segments: [
                        RealtimeHistoryAudioSegment(
                            relativePath: "\(microphoneDirectory)/segment-0001.m4a",
                            offset: 0,
                            duration: 0.25,
                            byteCount: byteCount(at: microphoneSegmentURL)
                        ),
                    ]
                ),
            ],
            delayedTranscriptSegments: [
                RealtimeHistoryTranscriptSegment(
                    source: .microphone,
                    offset: 0.05,
                    duration: 0.25,
                    text: "Mic hello.",
                    translatedText: "Mic hola."
                ),
            ]
        )

        return (
            session,
            {
                try? FileManager.default.removeItem(at: macURL)
                try? FileManager.default.removeItem(at: microphoneURL)
            }
        )
    }

    private func writeAudioSegment(to url: URL, frameCount: AVAudioFrameCount) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        try file.write(from: buffer)
    }

    private func audioFrameCount(_ data: Data) throws -> AVAudioFramePosition {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TLingo-Realtime-Test-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        return try AVAudioFile(forReading: url).length
    }

    private func byteCount(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
