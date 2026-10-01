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
            + ModelConfig.appleIntelligenceModels.map(\.id)
            + [free.id, premium.id, secondPremium.id])
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
