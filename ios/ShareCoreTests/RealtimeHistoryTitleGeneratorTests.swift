import Testing

@testable import ShareCore

@Suite("Realtime history title generator")
struct RealtimeHistoryTitleGeneratorTests {
    @Test("Selects the first free cloud model in server order")
    func selectsFirstFreeCloudModel() {
        let models = [
            ModelConfig(id: "premium", displayName: "Premium", isPremium: true),
            .appleTranslate,
            .foundationModel,
            ModelConfig(id: "free-first", displayName: "Free First"),
            ModelConfig(id: "free-second", displayName: "Free Second"),
        ]

        #expect(RealtimeHistoryTitleGenerator.firstFreeCloudModel(in: models)?.id == "free-first")
    }

    @Test("Cleans whitespace and enclosing quotes")
    func cleansTitle() {
        #expect(RealtimeHistoryTitleGenerator.cleanedTitle("  “Weekly\nproject   update”  ") == "Weekly project update")
        #expect(RealtimeHistoryTitleGenerator.cleanedTitle(" \n\t ") == nil)
    }

    @Test("Keeps the beginning and end of long transcripts")
    func condensesLongTranscript() {
        let halfLimit = RealtimeHistoryTitleGenerator.transcriptCharacterLimit / 2
        let prefix = String(repeating: "A", count: halfLimit)
        let middle = String(repeating: "M", count: 100)
        let suffix = String(repeating: "Z", count: halfLimit)

        let condensed = RealtimeHistoryTitleGenerator.condensedTranscript(prefix + middle + suffix)

        #expect(condensed.hasPrefix(prefix))
        #expect(condensed.hasSuffix(suffix))
        #expect(condensed.contains("[...]"))
        #expect(!condensed.contains(middle))
    }

    @Test("Uses the app language in the title prompt")
    func appLanguageIdentifier() {
        #expect(!RealtimeHistoryTitleGenerator.appLanguageIdentifier.isEmpty)
    }
}
