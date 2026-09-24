import Foundation
@testable import ShareCore
import Testing

@MainActor
@Suite("Conversation history snapshots")
struct ConversationHistorySnapshotTests {
    @Test
    func roundTripsConversationMessages() {
        let messages = [
            ChatMessage(role: "user", content: "Hello"),
            ChatMessage(role: "assistant", content: "Hi", reasoning: "Greeting"),
            ChatMessage(role: "user", content: "Continue"),
        ]
        let record = TranslationRecord(
            sourceText: "Hello",
            isConversation: true,
            conversationMessages: messages
        )

        #expect(record.conversationMessages.map(\.role) == ["user", "assistant", "user"])
        #expect(record.conversationMessages.map(\.content) == ["Hello", "Hi", "Continue"])
        #expect(record.conversationMessages[1].reasoning == "Greeting")
    }

    @Test
    func updatesOneRecordAcrossConversationTurns() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "ConversationHistorySnapshotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let service = TranslationHistoryService(
            storeURL: directory.appendingPathComponent("TranslationHistory.store"),
            userDefaults: defaults,
            pruneAudioRecordings: false
        )
        let requestID = UUID()
        let userMessage = ChatMessage(role: "user", content: "Hello")

        try service.saveThrowing(
            requestID: requestID,
            sourceText: "Hello",
            resultText: "",
            actionName: "Chat",
            targetLanguage: "",
            modelID: "test",
            modelDisplayName: "Test",
            duration: 0,
            isConversation: true,
            conversationMessages: [userMessage]
        )

        let assistantMessage = ChatMessage(role: "assistant", content: "Hi")
        try service.saveThrowing(
            requestID: requestID,
            sourceText: "Hello",
            resultText: "Hi",
            actionName: "Chat",
            targetLanguage: "",
            modelID: "test",
            modelDisplayName: "Test",
            duration: 1,
            isConversation: true,
            conversationMessages: [userMessage, assistantMessage]
        )

        let records = service.fetchAll()
        #expect(records.count == 1)
        #expect(records[0].modelResults.map(\.resultText) == ["Hi"])
        #expect(records[0].conversationMessages.map(\.content) == ["Hello", "Hi"])
    }
}
