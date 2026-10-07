import Foundation
import FoundationModels

public enum FoundationModelAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case systemNotReady
    case privateCloudUnavailable
    case unavailable

    public var isAvailable: Bool {
        self == .available
    }

    public var localizedDescription: String {
        switch self {
        case .available:
            String(localized: "Private & On-Device")
        case .deviceNotEligible:
            String(localized: "This device does not support Apple Intelligence.")
        case .appleIntelligenceNotEnabled:
            String(localized: "Turn on Apple Intelligence to use this model.")
        case .modelNotReady:
            String(localized: "Apple Foundation Model is still downloading or not ready.")
        case .systemNotReady:
            String(localized: "Private Cloud Compute is still setting up. Try again later.")
        case .privateCloudUnavailable:
            String(localized: "Private Cloud Compute is unavailable.")
        case .unavailable:
            String(localized: "Apple Foundation Model is unavailable.")
        }
    }
}

public enum FoundationModelServiceError: LocalizedError {
    case unavailable(FoundationModelAvailability)
    case imagesNotSupported
    case annotationToolsNotSupported
    case emptyContent

    public var errorDescription: String? {
        switch self {
        case let .unavailable(availability):
            availability.localizedDescription
        case .imagesNotSupported:
            String(localized: "Apple Foundation Model does not support image input in TLingo yet.")
        case .annotationToolsNotSupported:
            String(localized: "Apple Foundation Model does not support history annotation tools yet.")
        case .emptyContent:
            String(localized: "Apple Foundation Model returned an empty response.")
        }
    }
}

public final class FoundationModelService: Sendable {
    public static let shared = FoundationModelService()

    struct ResolvedPrompt: Equatable {
        let instructions: String?
        let prompt: String
    }

    @Generable
    fileprivate struct GeneratedSentencePair {
        @Guide(description: "The original sentence from the input.")
        var original: String

        @Guide(description: "The translated version of the sentence.")
        var translation: String
    }

    @Generable
    fileprivate struct GeneratedSentencePairs {
        @Guide(description: "Sentence pairs in the same order as the input.", .minimumCount(1))
        var sentencePairs: [GeneratedSentencePair]
    }

    @Generable
    fileprivate struct GeneratedGrammarCheck {
        @Guide(description: "The user text rewritten with all grammar issues addressed. Preserve the original language.")
        var revisedText: String

        @Guide(description: "Compact Markdown explaining the issues and meaning.")
        var additionalText: String
    }

    public init() {}

    public static var availability: FoundationModelAvailability {
        resolveAvailability(SystemLanguageModel.default.availability)
    }

    public static func availability(for model: ModelConfig) -> FoundationModelAvailability {
        guard model.isPrivateCloudModel else { return availability }
        guard !BuildEnvironment.isDirectDistribution else { return .privateCloudUnavailable }
#if compiler(>=6.4)
        guard #available(iOS 27.0, macOS 27.0, *) else { return .privateCloudUnavailable }
        return resolveAvailability(PrivateCloudComputeLanguageModel().availability)
#else
        return .privateCloudUnavailable
#endif
    }

    public static func availabilityDescription(for model: ModelConfig) -> String {
        let availability = availability(for: model)
        if model.isPrivateCloudModel, availability.isAvailable {
            return String(localized: "Private Cloud Compute")
        }
        return availability.localizedDescription
    }

    static func resolveAvailability(
        _ availability: SystemLanguageModel.Availability
    ) -> FoundationModelAvailability {
        switch availability {
        case .available:
            .available
        case .unavailable(.deviceNotEligible):
            .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            .modelNotReady
        case .unavailable:
            .unavailable
        }
    }

#if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, *)
    static func resolveAvailability(
        _ availability: PrivateCloudComputeLanguageModel.Availability
    ) -> FoundationModelAvailability {
        switch availability {
        case .available:
            .available
        case .unavailable(.deviceNotEligible):
            .deviceNotEligible
        case .unavailable(.systemNotReady):
            .systemNotReady
        case .unavailable:
            .privateCloudUnavailable
        }
    }
#endif

    static func resolvePrompt(
        text: String,
        action: ActionConfig,
        targetLanguageDescriptor: String,
        sourceLanguageDescriptor: String
    ) -> ResolvedPrompt {
        let messages = action.promptMessages(
            text: text,
            targetLanguage: targetLanguageDescriptor,
            sourceLanguage: sourceLanguageDescriptor
        )
        return ResolvedPrompt(instructions: messages.system, prompt: messages.user)
    }

    public func perform(
        model: ModelConfig,
        text: String,
        action: ActionConfig,
        images: [ImageAttachment],
        targetLanguageDescriptor: String,
        sourceLanguageDescriptor: String,
        partialHandler: (@MainActor @Sendable (String, StreamingUpdate) -> Void)?
    ) async -> ModelExecutionResult {
        let start = Date()
        do {
            guard images.isEmpty else {
                throw FoundationModelServiceError.imagesNotSupported
            }
            let resolved = Self.resolvePrompt(
                text: text,
                action: action,
                targetLanguageDescriptor: targetLanguageDescriptor,
                sourceLanguageDescriptor: sourceLanguageDescriptor
            )
            let session = try Self.makeSession(model: model, instructions: resolved.instructions)

            switch action.outputType {
            case .sentencePairs:
                return try await performSentencePairs(
                    session: session,
                    prompt: resolved.prompt,
                    modelID: model.id,
                    start: start,
                    partialHandler: partialHandler
                )
            case .grammarCheck:
                return try await performGrammarCheck(
                    session: session,
                    prompt: resolved.prompt,
                    modelID: model.id,
                    start: start,
                    partialHandler: partialHandler
                )
            case .markdown, .diff, .translate:
                return try await performPlainText(
                    session: session,
                    prompt: resolved.prompt,
                    modelID: model.id,
                    start: start,
                    partialHandler: partialHandler
                )
            }
        } catch is CancellationError {
            return ModelExecutionResult(
                modelID: model.id,
                duration: Date().timeIntervalSince(start),
                response: .failure(CancellationError())
            )
        } catch {
            return ModelExecutionResult(
                modelID: model.id,
                duration: Date().timeIntervalSince(start),
                response: .failure(error)
            )
        }
    }

    public func continueConversation(
        messages: [LLMRequestPayload.Message],
        model: ModelConfig,
        partialHandler: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        guard !messages.contains(where: \.containsImages) else {
            throw FoundationModelServiceError.imagesNotSupported
        }
        guard let finalMessage = messages.last, finalMessage.role == "user" else {
            throw FoundationModelServiceError.emptyContent
        }

        let transcript = Transcript(entries: messages.dropLast().compactMap(Self.transcriptEntry))
        let session = try Self.makeSession(model: model, transcript: transcript)
        var finalText = ""
        for try await snapshot in session.streamResponse(to: finalMessage.textContent) {
            try Task.checkCancellation()
            finalText = snapshot.content
            await partialHandler(finalText)
        }

        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FoundationModelServiceError.emptyContent
        }
        return trimmed
    }

    private static func checkAvailability(for model: ModelConfig) throws {
        let availability = availability(for: model)
        guard availability.isAvailable else {
            throw FoundationModelServiceError.unavailable(availability)
        }
    }

    private static func makeSession(
        model: ModelConfig,
        instructions: String?
    ) throws -> LanguageModelSession {
        try checkAvailability(for: model)
        if model.isPrivateCloudModel {
#if compiler(>=6.4)
            guard #available(iOS 27.0, macOS 27.0, *) else {
                throw FoundationModelServiceError.unavailable(.privateCloudUnavailable)
            }
            return LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(),
                instructions: instructions
            )
#else
            throw FoundationModelServiceError.unavailable(.privateCloudUnavailable)
#endif
        }
        return LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
    }

    private static func makeSession(
        model: ModelConfig,
        transcript: Transcript
    ) throws -> LanguageModelSession {
        try checkAvailability(for: model)
        if model.isPrivateCloudModel {
#if compiler(>=6.4)
            guard #available(iOS 27.0, macOS 27.0, *) else {
                throw FoundationModelServiceError.unavailable(.privateCloudUnavailable)
            }
            return LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(),
                tools: [],
                transcript: transcript
            )
#else
            throw FoundationModelServiceError.unavailable(.privateCloudUnavailable)
#endif
        }
        return LanguageModelSession(model: SystemLanguageModel.default, tools: [], transcript: transcript)
    }

    private func performPlainText(
        session: LanguageModelSession,
        prompt: String,
        modelID: String,
        start: Date,
        partialHandler: (@MainActor @Sendable (String, StreamingUpdate) -> Void)?
    ) async throws -> ModelExecutionResult {
        var finalText = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            finalText = snapshot.content
            if let partialHandler {
                await partialHandler(modelID, .text(finalText))
            }
        }

        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FoundationModelServiceError.emptyContent
        }
        return ModelExecutionResult(
            modelID: modelID,
            duration: Date().timeIntervalSince(start),
            response: .success(trimmed)
        )
    }

    private func performSentencePairs(
        session: LanguageModelSession,
        prompt: String,
        modelID: String,
        start: Date,
        partialHandler: (@MainActor @Sendable (String, StreamingUpdate) -> Void)?
    ) async throws -> ModelExecutionResult {
        var finalPairs: [SentencePair] = []
        for try await snapshot in session.streamResponse(to: prompt, generating: GeneratedSentencePairs.self) {
            try Task.checkCancellation()
            finalPairs = snapshot.content.sentencePairs?.compactMap { pair in
                guard let original = pair.original?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let translation = pair.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !original.isEmpty, !translation.isEmpty
                else {
                    return nil
                }
                return SentencePair(original: original, translation: translation)
            } ?? []
            if let partialHandler, !finalPairs.isEmpty {
                await partialHandler(modelID, .sentencePairs(finalPairs))
            }
        }

        guard !finalPairs.isEmpty else {
            throw FoundationModelServiceError.emptyContent
        }
        return try Self.makeSentencePairsResult(
            finalPairs,
            modelID: modelID,
            duration: Date().timeIntervalSince(start)
        )
    }

    private func performGrammarCheck(
        session: LanguageModelSession,
        prompt: String,
        modelID: String,
        start: Date,
        partialHandler: (@MainActor @Sendable (String, StreamingUpdate) -> Void)?
    ) async throws -> ModelExecutionResult {
        var revisedText = ""
        var additionalText = ""
        for try await snapshot in session.streamResponse(to: prompt, generating: GeneratedGrammarCheck.self) {
            try Task.checkCancellation()
            revisedText = snapshot.content.revisedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            additionalText = snapshot.content.additionalText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let partialHandler {
                let text = [revisedText, additionalText].filter { !$0.isEmpty }.joined(separator: "\n\n")
                if !text.isEmpty {
                    await partialHandler(modelID, .text(text))
                }
            }
        }

        return try Self.makeGrammarCheckResult(
            revisedText: revisedText,
            additionalText: additionalText,
            modelID: modelID,
            duration: Date().timeIntervalSince(start)
        )
    }

    static func makeSentencePairsResult(
        _ pairs: [SentencePair],
        modelID: String = ModelConfig.foundationModelID,
        duration: TimeInterval
    ) throws -> ModelExecutionResult {
        guard !pairs.isEmpty else {
            throw FoundationModelServiceError.emptyContent
        }
        let combined = pairs.map { "\($0.original)\n\($0.translation)" }.joined(separator: "\n\n")
        return ModelExecutionResult(
            modelID: modelID,
            duration: duration,
            response: .success(combined),
            sentencePairs: pairs
        )
    }

    static func makeGrammarCheckResult(
        revisedText: String,
        additionalText: String,
        modelID: String = ModelConfig.foundationModelID,
        duration: TimeInterval
    ) throws -> ModelExecutionResult {
        guard !revisedText.isEmpty else {
            throw FoundationModelServiceError.emptyContent
        }
        let supplementalTexts = additionalText.isEmpty ? [] : [additionalText]
        let combined = ([revisedText] + supplementalTexts).joined(separator: "\n\n")
        return ModelExecutionResult(
            modelID: modelID,
            duration: duration,
            response: .success(combined),
            diffSource: revisedText,
            supplementalTexts: supplementalTexts
        )
    }

    private static func transcriptEntry(_ message: LLMRequestPayload.Message) -> Transcript.Entry? {
        let segments: [Transcript.Segment] = [
            .text(Transcript.TextSegment(content: message.textContent)),
        ]
        switch message.role {
        case "system":
            return .instructions(Transcript.Instructions(segments: segments, toolDefinitions: []))
        case "user":
            return .prompt(Transcript.Prompt(segments: segments))
        case "assistant":
            return .response(Transcript.Response(assetIDs: [], segments: segments))
        default:
            return nil
        }
    }
}
