import Foundation
import Testing

@testable import ShareCore

@MainActor
@Suite("Conversation model selection")
struct ConversationModelSelectionTests {
    private let freeModel = ModelConfig(id: "free", displayName: "Free")
    private let premiumModel = ModelConfig(id: "premium", displayName: "Premium", isPremium: true)

    @Test("Chat model preference persists and refreshes")
    func chatModelPreferencePersistsAndRefreshes() throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.chatModelID == nil)

        preferences.setChatModelID(premiumModel.id)
        #expect(AppPreferences(defaults: defaults).chatModelID == premiumModel.id)

        defaults.set(freeModel.id, forKey: "chat_model_id")
        preferences.refreshFromDefaults()
        #expect(preferences.chatModelID == freeModel.id)
    }

    @Test("Stored available model overrides the session model")
    func storedAvailableModelOverridesSessionModel() throws {
        let preferences = try makePreferences(chatModelID: premiumModel.id)
        let viewModel = makeViewModel(preferences: preferences)

        #expect(viewModel.model == premiumModel)
    }

    @Test("Missing stored model falls back without clearing the preference")
    func missingStoredModelFallsBackWithoutClearingPreference() throws {
        let preferences = try makePreferences(chatModelID: "missing")
        let viewModel = makeViewModel(preferences: preferences)

        #expect(viewModel.model == freeModel)
        #expect(preferences.chatModelID == "missing")
    }

    @Test("Changing model updates the preference")
    func changingModelUpdatesPreference() throws {
        let preferences = try makePreferences()
        let viewModel = makeViewModel(preferences: preferences)

        viewModel.model = premiumModel

        #expect(preferences.chatModelID == premiumModel.id)
    }

    @Test("Premium access gates the selected model")
    func premiumAccessGatesSelectedModel() throws {
        let preferences = try makePreferences(chatModelID: premiumModel.id)
        let viewModel = makeViewModel(preferences: preferences)

        #expect(!viewModel.canUseSelectedModel(isPro: false))
        #expect(viewModel.canUseSelectedModel(isPro: true))
    }

    private func makeViewModel(preferences: AppPreferences) -> ConversationViewModel {
        ConversationViewModel(
            session: ConversationSession(
                model: freeModel,
                action: ActionConfig(name: "Chat", prompt: ""),
                availableModels: [freeModel, premiumModel],
                messages: []
            ),
            llmService: .shared,
            preferences: preferences
        )
    }

    private func makePreferences(chatModelID: String? = nil) throws -> AppPreferences {
        let defaults = try makeDefaults()
        if let chatModelID {
            defaults.set(chatModelID, forKey: "chat_model_id")
        }
        return AppPreferences(defaults: defaults)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "ConversationModelSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
