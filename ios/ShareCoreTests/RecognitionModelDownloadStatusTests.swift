import Foundation
@testable import ShareCore
import Testing

struct RecognitionModelDownloadStatusTests {
    @Test func excludesResumedBytesFromSpeed() {
        var metrics = RecognitionModelDownloadMetrics()
        var status = RecognitionModelDownloadStatus()
        status.phase = .downloading
        status.totalBytes = 1000
        status.fractionCompleted = 0.4
        metrics.sample(&status, bytes: 400, at: 10)
        #expect(status.bytesPerSecond == nil)
        status.fractionCompleted = 0.6
        metrics.sample(&status, bytes: 600, at: 14)
        #expect(status.bytesPerSecond == 50)
        #expect(status.remainingSeconds == 8)
    }

    @Test func estimatesRemainingTimeWithoutInventingTotalBytes() throws {
        var metrics = RecognitionModelDownloadMetrics()
        var status = RecognitionModelDownloadStatus()
        status.phase = .downloading
        status.fractionCompleted = 0.2
        metrics.sample(&status, bytes: 200, at: 10)
        status.fractionCompleted = 0.4
        metrics.sample(&status, bytes: 400, at: 14)
        #expect(status.totalBytes == nil)
        #expect(status.bytesPerSecond == 50)
        let remaining = try #require(status.remainingSeconds)
        #expect(abs(remaining - 12) < 0.001)
    }

    @Test func clearsRateWhenStalledOrPreparing() {
        var metrics = RecognitionModelDownloadMetrics()
        var status = RecognitionModelDownloadStatus()
        status.phase = .downloading
        metrics.sample(&status, bytes: 100, at: 10)
        metrics.sample(&status, bytes: 200, at: 11)
        metrics.sample(&status, bytes: 200, at: 18)
        #expect(status.bytesPerSecond == 0)
        #expect(status.remainingSeconds == nil)
        status.phase = .installing
        metrics.sample(&status, bytes: 300, at: 19)
        #expect(status.bytesPerSecond == nil)
        #expect(status.remainingDescription == nil)
    }

    @Test func resetsRateWhenPartialFileRestarts() {
        var metrics = RecognitionModelDownloadMetrics()
        var status = RecognitionModelDownloadStatus()
        status.phase = .downloading
        metrics.sample(&status, bytes: 400, at: 10)
        metrics.sample(&status, bytes: 100, at: 11)
        #expect(status.bytesPerSecond == nil)
        #expect(status.remainingSeconds == nil)
        metrics.sample(&status, bytes: 200, at: 12)
        #expect(status.bytesPerSecond == 100)
    }

    @Test(arguments: [
        RecognitionModelDownloadStatus.Phase.completed, .failed, .cancelled,
    ])
    func terminalStatesAreNotActive(_ phase: RecognitionModelDownloadStatus.Phase) {
        var status = RecognitionModelDownloadStatus()
        status.phase = phase
        #expect(status.isActive == false)
    }
}
