import Foundation
@testable import ShareCore
import Testing

@MainActor
struct HomeRequestRegressionTests {
    @Test("Trial setup failures deliver one terminal result per model")
    func trialSetupFailuresAreTerminal() async {
        let session = URLSession(configuration: CoreBlockedURLProtocol.configuration)
        defer { session.invalidateAndCancel() }
        let service = LLMService(urlSession: session, trialDeviceID: { _ in
            throw LLMServiceError.trialUnavailable
        })
        let models = [ModelConfig(id: "trial-a", displayName: "A"), ModelConfig(id: "trial-b", displayName: "B")]
        var completed: [ModelExecutionResult] = []
        let results = await service.perform(
            text: "Check this sentence.",
            with: ActionConfig(name: "Check", prompt: "{{text}}"),
            models: models,
            targetLanguageDescriptor: "English",
            onboardingTrial: true,
            refreshEntitlement: false,
            cachedIsPremium: false,
            completionHandler: { completed.append($0) }
        )
        #expect(Set(results.map(\.modelID)) == Set(models.map(\.id)))
        #expect(Set(completed.map(\.modelID)) == Set(models.map(\.id)))
        #expect(results.count == models.count)
        #expect(completed.count == models.count)
        for result in results {
            guard case let .failure(error) = result.response else {
                Issue.record("Trial setup unexpectedly succeeded")
                continue
            }
            guard case .trialUnavailable = error as? LLMServiceError else {
                Issue.record("Expected the original trial registration error, got \(error)")
                continue
            }
        }
    }

    @Test("Cancelled trial setup does not publish a failure")
    func cancelledTrialSetupStaysSilent() async {
        let session = URLSession(configuration: CoreBlockedURLProtocol.configuration)
        defer { session.invalidateAndCancel() }
        let service = LLMService(urlSession: session, trialDeviceID: { _ in throw CancellationError() })
        let results = await service.perform(
            text: "Hello", with: ActionConfig(name: "Check", prompt: "{{text}}"),
            models: [.init(id: "trial", displayName: "Trial")],
            targetLanguageDescriptor: "English", onboardingTrial: true,
            completionHandler: { _ in Issue.record("Cancellation published a completion") }
        )
        #expect(results.isEmpty)
    }

    @Test("Extension chat skips enabled direct translators")
    func contextChatUsesChatModel() throws {
        let harness = try HomeRequestHarness()
        defer { harness.cleanup() }
        let cloud = ModelConfig(id: "chat", displayName: "Chat", isDefault: true)
        harness.preferences.setEnabledModelIDs([ModelConfig.microsoftTranslateID, cloud.id])
        let model = harness.makeModel(models: [cloud])
        let conversation = try #require(model.createContextConversation(contextText: "Selected text"))
        #expect(conversation.model.id == cloud.id)
        #expect(conversation.availableModels.allSatisfy { $0.isDirectTranslation == false })
        #expect(conversation.messages.first?.content.contains("Selected text") == true)
    }

    @Test("Extension chat without an enabled AI model reports failure instead of opening a direct model")
    func contextChatWithoutAIReportsFailure() throws {
        let harness = try HomeRequestHarness()
        defer { harness.cleanup() }
        harness.preferences.setEnabledModelIDs([ModelConfig.microsoftTranslateID])
        let model = harness.makeModel(models: [])
        #expect(model.createContextConversation(contextText: "Selected text") == nil)
        #expect(model.modelRuns.contains {
            if case .failure = $0.status {
                return true
            }
            return false
        })
    }

    @Test("Keyboard swap uses the same fixed-target detection as requests", arguments: [
        "会议改到周四下午了，请大家准时参加",
        "A reunião foi transferida para quinta-feira à tarde, por favor cheguem a horas.",
    ])
    func swapPreservesDetectedSource(text: String) throws {
        let harness = try HomeRequestHarness()
        defer { harness.cleanup() }
        harness.preferences.setSourceLanguage(.auto)
        harness.preferences.setTargetLanguage(.japanese)
        let model = harness.makeModel(models: [])
        model.inputText = text
        let resolution = HomeViewModel.resolveLanguages(
            text: text, sourcePreference: .auto, preferredTarget: .japanese, override: nil
        )
        let source = try #require(resolution.displaySource)
        model.swapInputLanguages()
        #expect(harness.preferences.sourceLanguage == .japanese)
        #expect(harness.preferences.targetLanguage.rawValue == source.rawValue)
    }

    @Test("Minimal detected identifiers retain source descriptors", arguments: [
        ("zh", SourceLanguageOption.simplifiedChinese),
        ("zh-TW", .traditionalChinese),
        ("pt", .portugueseBrazil),
    ])
    func minimalSourceDescriptors(code: String, source: SourceLanguageOption) {
        let pair = HomeViewModel.ResolvedLanguagePair(target: .japanese, sourceCode: code)
        #expect(pair.sourceLanguageDescriptor == source.promptDescriptor)
    }

    @Test("Continuation keeps request languages after preferences and preview change")
    func continuationKeepsOriginatingLanguages() throws {
        let harness = try HomeRequestHarness()
        defer { harness.cleanup() }
        harness.preferences.setSourceLanguage(.english)
        harness.preferences.setTargetLanguage(.simplifiedChinese)
        harness.preferences.setHasAcceptedDataSharing(true)
        let cloud = ModelConfig(id: "trial", displayName: "Trial")
        let model = harness.makeModel(models: [cloud], trialModels: [cloud])
        model.inputText = "The meeting has moved to Thursday afternoon."
        let action = try #require(model.selectedAction)
        let original = action.promptMessages(
            text: model.inputText, targetLanguage: TargetLanguageOption.simplifiedChinese.promptDescriptor,
            sourceLanguage: SourceLanguageOption.english.promptDescriptor
        )
        model.performSelectedAction(refreshEntitlement: false)
        harness.preferences.setTargetLanguage(.japanese)
        harness.preferences.setSourceLanguage(.french)
        model.clearDetectedSourceLanguage()
        let run = HomeViewModel.ModelRunViewState(
            model: cloud, status: .success(.init(text: "译文", copyText: "译文", duration: 1))
        )
        let conversation = try #require(model.createConversation(from: run))
        #expect(conversation.messages.first { $0.role == "system" }?.content == original.system)
        #expect(conversation.messages.first { $0.role == "user" }?.content == original.user)
        #expect(conversation.messages.last?.content == "译文")
    }

    @Test("A handed-off result retains its originating languages")
    func handedOffContinuationKeepsOriginatingLanguages() throws {
        let harness = try HomeRequestHarness()
        defer { harness.cleanup() }
        harness.preferences.setSourceLanguage(.english)
        harness.preferences.setTargetLanguage(.simplifiedChinese)
        harness.preferences.setHasAcceptedDataSharing(true)
        let cloud = ModelConfig(id: "trial", displayName: "Trial")
        let originalModel = harness.makeModel(models: [cloud], trialModels: [cloud])
        originalModel.inputText = "The meeting has moved to Thursday afternoon."
        let action = try #require(originalModel.selectedAction)
        originalModel.performSelectedAction(refreshEntitlement: false)
        let snapshot = originalModel.captureStateSnapshot()
        var run = try #require(snapshot.modelRuns.first)
        run.status = .success(.init(text: "译文", copyText: "译文", duration: 1))
        harness.preferences.setSourceLanguage(.french)
        harness.preferences.setTargetLanguage(.japanese)
        let destination = harness.makeModel(models: [cloud])
        destination.adoptStateSnapshot(.init(
            inputText: snapshot.inputText,
            currentRequestInputText: snapshot.currentRequestInputText,
            selectedActionID: snapshot.selectedActionID,
            modelRuns: [run]
        ))
        let conversation = try #require(destination.createConversation(from: run))
        let expected = action.promptMessages(
            text: snapshot.currentRequestInputText,
            targetLanguage: TargetLanguageOption.simplifiedChinese.promptDescriptor,
            sourceLanguage: SourceLanguageOption.english.promptDescriptor
        )
        #expect(conversation.messages.first { $0.role == "system" }?.content == expected.system)
    }
}

@MainActor
private struct HomeRequestHarness {
    let defaults: UserDefaults
    let suite = "HomeRequestRegressionTests.\(UUID().uuidString)"
    let preferences: AppPreferences
    let session: URLSession

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        preferences = AppPreferences(defaults: defaults, preferredLanguages: ["en"])
        session = URLSession(configuration: CoreBlockedURLProtocol.configuration)
    }

    func makeModel(models: [ModelConfig], trialModels: [ModelConfig] = []) -> HomeViewModel {
        HomeViewModel(
            configurationStore: AppConfigurationStore(snapshot: true, preferences: preferences),
            llmService: LLMService(urlSession: session, trialDeviceID: { _ in
                throw LLMServiceError.trialUnavailable
            }),
            preferences: preferences,
            supportsAppleTranslate: false,
            onboardingTrialModels: trialModels,
            initialModels: models,
            premiumAccess: { false }
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        session.invalidateAndCancel()
    }
}

private class CoreBlockedURLProtocol: URLProtocol {
    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return configuration
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Issue.record("Unexpected network request in isolated core regression")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
