import Foundation
import Testing

@testable import ShareCore

@MainActor
@Suite("SpeechRecognitionService lifecycle")
struct SpeechRecognitionServiceTests {
    @Test("Successful transcription returns to idle")
    func successfulTranscriptionReturnsToIdle() async throws {
        let service = SpeechRecognitionService { _ in "Hello" }
        let url = try temporaryAudioFile()

        service.beginTranscription(audioFileURL: url)
        await waitUntilIdle(service)

        #expect(service.state == .idle)
        #expect(service.transcript == "Hello")
        #expect(service.error == nil)
    }

    @Test("Empty transcription returns to idle")
    func emptyTranscriptionReturnsToIdle() async throws {
        let service = SpeechRecognitionService { _ in "" }
        let url = try temporaryAudioFile()

        service.beginTranscription(audioFileURL: url)
        await waitUntilIdle(service)

        #expect(service.state == .idle)
        #expect(service.transcript.isEmpty)
        #expect(service.error == nil)
    }

    @Test("Failed transcription returns to idle")
    func failedTranscriptionReturnsToIdle() async throws {
        let service = SpeechRecognitionService { _ in
            throw TestError.failed
        }
        let url = try temporaryAudioFile()

        service.beginTranscription(audioFileURL: url)
        await waitUntilIdle(service)

        #expect(service.state == .idle)
        #expect(service.error != nil)
    }

    @Test("Cancellation returns to idle")
    func cancellationReturnsToIdle() async throws {
        let stub = TranscriptionStub()
        let service = SpeechRecognitionService { url in
            await stub.transcribe(url)
        }
        let url = try temporaryAudioFile()

        service.beginTranscription(audioFileURL: url)
        await stub.waitUntilPending(url)
        service.cancelRecording()

        #expect(service.state == .idle)
        #expect(service.transcript.isEmpty)

        await stub.resume(url, with: "Cancelled result")
        await Task.yield()
        #expect(service.state == .idle)
        #expect(service.transcript.isEmpty)
    }

    @Test("Stale transcription cannot overwrite a newer recording")
    func staleTranscriptionCannotOverwriteNewerRecording() async throws {
        let stub = TranscriptionStub()
        let service = SpeechRecognitionService { url in
            await stub.transcribe(url)
        }
        let firstURL = try temporaryAudioFile()
        let secondURL = try temporaryAudioFile()

        service.beginTranscription(audioFileURL: firstURL)
        await stub.waitUntilPending(firstURL)
        service.cancelRecording()
        service.beginTranscription(audioFileURL: secondURL)
        await stub.waitUntilPending(secondURL)

        await stub.resume(secondURL, with: "New")
        await waitUntilIdle(service)
        await stub.resume(firstURL, with: "Old")
        await Task.yield()

        #expect(service.state == .idle)
        #expect(service.transcript == "New")
    }

    private func temporaryAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try Data().write(to: url)
        return url
    }

    private func waitUntilIdle(_ service: SpeechRecognitionService) async {
        while service.state != .idle {
            await Task.yield()
        }
    }
}

private enum TestError: Error {
    case failed
}

private actor TranscriptionStub {
    private var continuations: [URL: CheckedContinuation<String, Never>] = [:]

    func transcribe(_ url: URL) async -> String {
        await withCheckedContinuation { continuation in
            continuations[url] = continuation
        }
    }

    func waitUntilPending(_ url: URL) async {
        while continuations[url] == nil {
            await Task.yield()
        }
    }

    func resume(_ url: URL, with value: String) {
        continuations.removeValue(forKey: url)?.resume(returning: value)
    }
}
