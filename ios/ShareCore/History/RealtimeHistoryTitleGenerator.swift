import Foundation

enum RealtimeHistoryTitleGenerator {
    static let transcriptCharacterLimit = 12000

    static func generateTitle(for sourceText: String) async throws -> String? {
        let transcript = condensedTranscript(sourceText)
        guard !transcript.isEmpty else { return nil }

        let models = try await ModelsService.shared.fetchModels(forceRefresh: false)
        guard let model = firstFreeCloudModel(in: models) else {
            return nil
        }

        let messages = [
            LLMRequestPayload.Message(
                role: "system",
                content: """
                The app UI language is \(appLanguageIdentifier). \
                Summarize the transcript as one short history title in that language, \
                regardless of the transcript's language. \
                Return only the plain-text title without quotes, markdown, labels, or explanation.
                """
            ),
            LLMRequestPayload.Message(role: "user", content: transcript),
        ]
        let response = try await LLMService.shared.sendContinuationOnce(
            messages: messages,
            model: model
        )
        return cleanedTitle(response)
    }

    static var appLanguageIdentifier: String {
        Locale.preferredLanguages.first ?? Locale.current.identifier
    }

    static func firstFreeCloudModel(in models: [ModelConfig]) -> ModelConfig? {
        models.first { !$0.isPremium && !$0.isDirectTranslation && !$0.isFoundationModel }
    }

    static func condensedTranscript(_ sourceText: String) -> String {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > transcriptCharacterLimit else { return trimmed }

        let halfLimit = transcriptCharacterLimit / 2
        return "\(trimmed.prefix(halfLimit))\n\n[...]\n\n\(trimmed.suffix(halfLimit))"
    }

    static func cleanedTitle(_ response: String) -> String? {
        var title = response
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let quotePairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("“", "”"),
            ("‘", "’"),
        ]
        let hasEnclosingQuotes = if let first = title.first, let last = title.last {
            quotePairs.contains { $0.0 == first && $0.1 == last }
        } else {
            false
        }
        if hasEnclosingQuotes {
            title.removeFirst()
            title.removeLast()
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return title.isEmpty ? nil : title
    }
}
