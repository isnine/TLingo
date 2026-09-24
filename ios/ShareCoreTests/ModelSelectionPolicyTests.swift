//
//  ModelSelectionPolicyTests.swift
//  ShareCoreTests
//

import ShareCore
import Testing

struct ModelSelectionPolicyTests {
    private let firstFree = ModelConfig(id: "gpt-5-nano", displayName: "GPT-5 Nano", isDefault: true)
    private let secondFree = ModelConfig(id: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash")
    private let thirdFree = ModelConfig(id: "kimi-k2.6", displayName: "Kimi K2.6")
    private let premium = ModelConfig(id: "gpt-5.4", displayName: "GPT-5.4", isPremium: true)

    @Test("Free users cannot enable a second cloud model")
    func freeUsersCannotEnableSecondCloudModel() {
        let result = ModelSelectionPolicy.toggle(
            secondFree,
            enabledIDs: [firstFree.id],
            availableModels: [firstFree, secondFree, thirdFree],
            isPro: false
        )

        #expect(result.enabledIDs == [firstFree.id])
        #expect(result.reason == .freeCloudModelLimitReached)
    }

    @Test("Pro users can enable more than two cloud models")
    func proUsersCanEnableMoreThanTwoCloudModels() {
        let result = ModelSelectionPolicy.toggle(
            thirdFree,
            enabledIDs: [firstFree.id, secondFree.id],
            availableModels: [firstFree, secondFree, thirdFree],
            isPro: true
        )

        #expect(result.enabledIDs == [firstFree.id, secondFree.id, thirdFree.id])
        #expect(result.reason == nil)
    }

    @Test("Direct translation services do not count toward the free cloud model limit")
    func directTranslationServicesDoNotCountTowardFreeLimit() {
        let googleResult = ModelSelectionPolicy.toggle(
            ModelConfig.googleTranslate,
            enabledIDs: [firstFree.id, secondFree.id],
            availableModels: [firstFree, secondFree, ModelConfig.googleTranslate],
            isPro: false
        )

        #expect(googleResult.enabledIDs == [firstFree.id, secondFree.id, ModelConfig.googleTranslateID])
        #expect(googleResult.reason == nil)

        let appleResult = ModelSelectionPolicy.toggle(
            ModelConfig.appleTranslate,
            enabledIDs: googleResult.enabledIDs,
            availableModels: [firstFree, secondFree, ModelConfig.googleTranslate, ModelConfig.appleTranslate],
            isPro: false
        )

        let expectedIDs = Set([firstFree.id, secondFree.id, ModelConfig.googleTranslateID, ModelConfig.appleTranslateID])
        #expect(appleResult.enabledIDs == expectedIDs)
        #expect(appleResult.reason == nil)
    }

    @Test("Foundation Model does not count toward the free cloud model limit")
    func foundationModelDoesNotCountTowardFreeLimit() {
        let result = ModelSelectionPolicy.toggle(
            ModelConfig.foundationModel,
            enabledIDs: [firstFree.id, secondFree.id],
            availableModels: [firstFree, secondFree, ModelConfig.foundationModel],
            isPro: false
        )

        #expect(result.enabledIDs == [firstFree.id, secondFree.id, ModelConfig.foundationModelID])
        #expect(result.reason == nil)
    }

    @Test("Free users cannot enable premium cloud models")
    func freeUsersCannotEnablePremiumCloudModels() {
        let result = ModelSelectionPolicy.toggle(
            premium,
            enabledIDs: [firstFree.id],
            availableModels: [firstFree, premium],
            isPro: false
        )

        #expect(result.enabledIDs == [firstFree.id])
        #expect(result.reason == .requiresPro)
    }

    @Test("Disabling the last model falls back to the default available model")
    func disablingLastModelFallsBackToDefaultAvailableModel() {
        let result = ModelSelectionPolicy.toggle(
            secondFree,
            enabledIDs: [secondFree.id],
            availableModels: [firstFree, secondFree],
            isPro: false
        )

        #expect(result.enabledIDs == [firstFree.id])
        #expect(result.reason == .keptDefaultModel)
    }

    @Test("Callable cloud selection skips direct and disabled models")
    func callableCloudSelectionSkipsDirectAndDisabledModels() {
        let selected = ModelSelectionPolicy.firstCallableCloudModelID(
            enabledIDs: [
                ModelConfig.appleTranslateID,
                ModelConfig.googleTranslateID,
                ModelConfig.foundationModelID,
                secondFree.id,
            ],
            availableModels: [
                firstFree,
                ModelConfig.appleTranslate,
                ModelConfig.googleTranslate,
                ModelConfig.foundationModel,
                secondFree,
            ],
            isPro: false
        )

        #expect(selected == secondFree.id)
    }

    @Test("Callable cloud selection respects premium access")
    func callableCloudSelectionRespectsPremiumAccess() {
        let freeSelection = ModelSelectionPolicy.firstCallableCloudModelID(
            enabledIDs: [premium.id],
            availableModels: [premium],
            isPro: false
        )
        let proSelection = ModelSelectionPolicy.firstCallableCloudModelID(
            enabledIDs: [premium.id],
            availableModels: [premium],
            isPro: true
        )

        #expect(freeSelection == nil)
        #expect(proSelection == premium.id)
    }
}
