import FoundationModels
import Testing

@testable import ShareCore

@Suite("FoundationModelService")
struct FoundationModelServiceTests {
    @Test("Availability reasons map to user-facing states")
    func availabilityMapping() {
        #expect(FoundationModelService.resolveAvailability(.available) == .available)
        #expect(
            FoundationModelService.resolveAvailability(.unavailable(.deviceNotEligible))
                == .deviceNotEligible
        )
        #expect(
            FoundationModelService.resolveAvailability(.unavailable(.appleIntelligenceNotEnabled))
                == .appleIntelligenceNotEnabled
        )
        #expect(
            FoundationModelService.resolveAvailability(.unavailable(.modelNotReady))
                == .modelNotReady
        )
    }

    @Test("Inline action prompt uses substituted prompt as user content")
    func inlinePrompt() {
        let action = ActionConfig(
            name: "Translate",
            prompt: "Translate {{text}} from {{sourceLanguage}} to {{targetLanguage}}."
        )

        let resolved = FoundationModelService.resolvePrompt(
            text: "Hello",
            action: action,
            targetLanguageDescriptor: "Chinese",
            sourceLanguageDescriptor: "English"
        )

        #expect(resolved.instructions == nil)
        #expect(resolved.prompt == "Translate Hello from English to Chinese.")
    }

    @Test("System prompt keeps user text separate")
    func systemPrompt() {
        let action = ActionConfig(name: "Polish", prompt: "Polish the user's text.")

        let resolved = FoundationModelService.resolvePrompt(
            text: "hello",
            action: action,
            targetLanguageDescriptor: "",
            sourceLanguageDescriptor: ""
        )

        #expect(resolved.instructions == "Polish the user's text.")
        #expect(resolved.prompt == "hello")
    }

    @Test("Built-in prompt wraps user text in source tags")
    func builtInPromptWrapsSource() throws {
        let action = try #require(AppConfigurationStore.builtInActions.first { $0.name == "Polish" })

        let resolved = FoundationModelService.resolvePrompt(
            text: "hello",
            action: action,
            targetLanguageDescriptor: "",
            sourceLanguageDescriptor: ""
        )

        #expect(resolved.instructions == action.prompt)
        #expect(resolved.prompt == "<source>\nhello\n</source>")
    }

    @Test("Sentence pairs map to the existing result shape")
    func sentencePairResult() throws {
        let pairs = [
            SentencePair(original: "Hello.", translation: "你好。"),
        ]

        let result = try FoundationModelService.makeSentencePairsResult(pairs, duration: 1)

        #expect(result.modelID == ModelConfig.foundationModelID)
        #expect(result.sentencePairs == pairs)
        #expect(try result.response.get() == "Hello.\n你好。")
    }

    @Test("Grammar output maps revised and supplemental text")
    func grammarResult() throws {
        let result = try FoundationModelService.makeGrammarCheckResult(
            revisedText: "I am ready.",
            additionalText: "## Issues\n- Fixed agreement.",
            duration: 1
        )

        #expect(result.diffSource == "I am ready.")
        #expect(result.supplementalTexts == ["## Issues\n- Fixed agreement."])
        #expect(try result.response.get() == "I am ready.\n\n## Issues\n- Fixed agreement.")
    }
}
