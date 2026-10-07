import Foundation
@testable import ShareCore
import Testing

@MainActor
struct ModelResultOrderTests {
    private let premium = ModelConfig(id: "premium", displayName: "Premium", isPremium: true)
    private let free = ModelConfig(id: "free", displayName: "Free")

    private func completed(_ model: ModelConfig, at time: TimeInterval) -> HomeViewModel.ModelRunViewState {
        var run = HomeViewModel.ModelRunViewState(
            model: model,
            status: .success(.init(text: "Result", copyText: "Result", duration: 1))
        )
        run.firstOutputAt = Date(timeIntervalSince1970: time)
        return run
    }

    @Test func completionOrderUsesArrivalNotDurationOrCatalog() {
        let runs = [completed(premium, at: 20), completed(free, at: 10)]
        #expect(HomeViewModel.sortModelRuns(
            runs, order: .firstCompletedFirst, catalog: [premium, free]
        ).map(\.id) == [free.id, premium.id])
        #expect(HomeViewModel.sortModelRuns(
            runs, order: .modelList, catalog: [premium, free]
        ).map(\.id) == [premium.id, free.id])
    }

    @Test func catalogPreservesOrderWithinEachGroup() {
        let secondPremium = ModelConfig(id: "premium-2", displayName: "Premium 2", isPremium: true)
        let catalog = ModelListSections.resultOrder(cloudModels: [free, premium, secondPremium])
        #expect(catalog.map(\.id) == ModelConfig.translationServices.map(\.id)
            + [free.id, premium.id, secondPremium.id]
            + ModelConfig.appleIntelligenceModels.map(\.id))
    }

    @Test func customGroupAndModelOrderControlsResults() {
        let secondPremium = ModelConfig(id: "premium-2", displayName: "Premium 2", isPremium: true)
        var order = ModelListOrder()
        order.sections = [.premium, .free, .translation, .appleIntelligence]
        order.modelIDsBySection[ModelListSection.premium.rawValue] = [secondPremium.id, premium.id]
        order.modelIDsBySection[ModelListSection.translation.rawValue] = [
            ModelConfig.microsoftTranslateID, ModelConfig.appleTranslateID,
        ]
        let catalog = ModelListSections.resultOrder(cloudModels: [free, premium, secondPremium], order: order)
        #expect(catalog.map(\.id) == [secondPremium.id, premium.id, free.id]
            + [ModelConfig.microsoftTranslateID, ModelConfig.appleTranslateID]
            + ModelConfig.appleIntelligenceModels.map(\.id))
        let runs = [completed(free, at: 10), completed(premium, at: 20), completed(secondPremium, at: 30)]
        #expect(HomeViewModel.sortModelRuns(runs, order: .modelList, catalog: catalog).map(\.id)
            == [secondPremium.id, premium.id, free.id])
        #expect(HomeViewModel.sortModelRuns(runs, order: .firstCompletedFirst, catalog: catalog).map(\.id)
            == [free.id, premium.id, secondPremium.id])
    }

    @Test func catalogChangesKeepSavedOrderAndAppendNewModels() {
        let newModel = ModelConfig(id: "new-free", displayName: "New Free")
        var order = ModelListOrder()
        order.sections = [.free, .free]
        order.modelIDsBySection[ModelListSection.free.rawValue] = ["removed", free.id, free.id]
        #expect(order.orderedSections == [.free, .translation, .premium, .appleIntelligence])
        #expect(order.models(in: .free, cloudModels: [newModel, premium, free]).map(\.id)
            == [free.id, newModel.id])
        #expect(order.models(in: .premium, cloudModels: [newModel, premium, free]) == [premium])
    }

    @Test func listOrderPersistsAndRefreshesAcrossPreferenceInstances() throws {
        let suite = "ModelListOrderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.modelListOrder == ModelListOrder())
        var order = ModelListOrder()
        order.sections = [.premium, .free, .appleIntelligence, .translation]
        order.modelIDsBySection[ModelListSection.premium.rawValue] = [premium.id]
        preferences.setModelListOrder(order)
        let other = AppPreferences(defaults: defaults)
        #expect(other.modelListOrder == order)
        order.modelIDsBySection[ModelListSection.free.rawValue] = [free.id]
        other.setModelListOrder(order)
        preferences.refreshFromDefaults()
        #expect(preferences.modelListOrder == order)
        defaults.set(Data("invalid".utf8), forKey: "model_list_order")
        preferences.refreshFromDefaults()
        #expect(preferences.modelListOrder == ModelListOrder())
    }

    @Test func pendingAndFailuresRemainBelowResultsForArrivalOrders() {
        let pending = HomeViewModel.ModelRunViewState(model: premium, status: .running(start: Date()))
        let failed = HomeViewModel.ModelRunViewState(
            model: ModelConfig.appleTranslate,
            status: .failure(message: "Failed", duration: 0)
        )
        #expect(HomeViewModel.sortModelRuns(
            [failed, pending, completed(free, at: 10)],
            order: .firstCompletedFirst,
            catalog: [premium, free, ModelConfig.appleTranslate]
        ).map(\.id) == [free.id, premium.id, ModelConfig.appleTranslateID])
        #expect(HomeViewModel.sortModelRuns(
            [failed, pending, completed(free, at: 10)],
            order: .modelList, catalog: [ModelConfig.appleTranslate, premium, free]
        ).map(\.id) == [ModelConfig.appleTranslateID, premium.id, free.id])
    }

    @Test func equalTimesAndUnknownModelsHaveStableOrder() {
        let runs = [completed(free, at: 10), completed(premium, at: 10)]
        #expect(HomeViewModel.sortModelRuns(
            runs, order: .firstCompletedFirst, catalog: []
        ).map(\.id) == runs.map(\.id))
        #expect(HomeViewModel.sortModelRuns(
            runs, order: .modelList, catalog: [premium, free]
        ).map(\.id) == [premium.id, free.id])
    }

    @Test func retryUsesNewCompletionTime() {
        var retried = completed(free, at: 10)
        retried.status = .running(start: Date())
        retried.firstOutputAt = nil
        let other = completed(premium, at: 20)
        #expect(HomeViewModel.sortModelRuns(
            [retried, other], order: .firstCompletedFirst, catalog: [free, premium]
        ).map(\.id) == [premium.id, free.id])
        retried = completed(free, at: 30)
        #expect(HomeViewModel.sortModelRuns(
            [retried, other], order: .firstCompletedFirst, catalog: [free, premium]
        ).map(\.id) == [premium.id, free.id])
    }

    @Test func preferenceDefaultsPersistsAndRefreshes() throws {
        let suite = "ModelResultOrderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.modelResultOrder == .firstCompletedFirst)
        for order in ModelResultOrder.allCases {
            preferences.setModelResultOrder(order)
            #expect(AppPreferences(defaults: defaults).modelResultOrder == order)
        }
        defaults.set("lastCompletedFirst", forKey: "model_result_order")
        preferences.refreshFromDefaults()
        #expect(preferences.modelResultOrder == .firstCompletedFirst)
        defaults.set("invalid", forKey: "model_result_order")
        preferences.refreshFromDefaults()
        #expect(preferences.modelResultOrder == .firstCompletedFirst)
    }
}
