import Foundation
@testable import ShareCore
import Testing

@Suite("History annotations")
struct HistoryAnnotationTests {
    @Test("History conversation context exposes stable record and cell IDs")
    func historyConversationContextExposesStableRecordAndCellIDs() {
        let recordID = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
        let segmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!
        let session = RealtimeHistorySession(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000016")!,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 105),
            duration: 5,
            inputSource: RealtimeHistoryAudioSource.macAudio.title,
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: "apple-translate",
            modelDisplayName: "Apple Translate",
            segments: [
                RealtimeHistorySegment(id: segmentID, offset: 0, sourceText: "Welcome.", translatedText: "Bienvenido."),
            ]
        )
        let record = TranslationRecord(
            id: recordID,
            sourceText: "Welcome.",
            actionName: TranslationRecord.realtimeActionName
        )
        record.realtimeSession = session

        let context = record.historyConversationContext

        #expect(context.contains("History Record ID: \(recordID.uuidString)"))
        #expect(context.contains("Cell ID: \(segmentID.uuidString)"))
        #expect(context.contains("Original:"))
        #expect(context.contains("Translation:"))
        #expect(record.annotationTargetIDs == [segmentID])
    }

    @Test("Record annotations are stored by target ID")
    func recordAnnotationsAreStoredByTargetID() {
        let recordID = UUID(uuidString: "00000000-0000-0000-0000-000000000017")!
        let record = TranslationRecord(id: recordID, sourceText: "Welcome.")
        var annotations = record.historyAnnotations
        annotations[recordID.uuidString] = "  **Important**  "
        record.historyAnnotations = annotations

        #expect(record.annotation(for: recordID) == "**Important**")
        #expect(record.annotationTargetIDs == [recordID])
    }
}
