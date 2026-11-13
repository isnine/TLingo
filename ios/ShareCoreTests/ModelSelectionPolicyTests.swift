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

    @Test("Free users switch cloud models by selecting another free model")
    func freeUsersSwitchCloudModels() {
        let result = ModelSelectionPolicy.toggle(
            secondFree,
            enabledIDs: [firstFree.id],
            availableModels: [firstFree, secondFree, thirdFree],
            isPro: false
        )

        #expect(result.enabledIDs == [secondFree.id])
        #expect(result.reason == nil)

        let switchedBack = ModelSelectionPolicy.toggle(
            firstFree,
            enabledIDs: result.enabledIDs,
            availableModels: [firstFree, secondFree, thirdFree],
            isPro: false
        )

        #expect(switchedBack.enabledIDs == [firstFree.id])
        #expect(switchedBack.reason == nil)
    }

    @Test("Free users can switch after trying to deselect their last model")
    func freeUsersCanSwitchAfterKeepingLastModel() {
        let kept = ModelSelectionPolicy.toggle(
            firstFree,
            enabledIDs: [firstFree.id],
            availableModels: [firstFree, secondFree],
            isPro: false
        )

        #expect(kept.enabledIDs == [firstFree.id])
        #expect(kept.reason == .keptDefaultModel)

        let switched = ModelSelectionPolicy.toggle(
            secondFree,
            enabledIDs: kept.enabledIDs,
            availableModels: [firstFree, secondFree],
            isPro: false
        )

        #expect(switched.enabledIDs == [secondFree.id])
        #expect(switched.reason == nil)
    }

    @Test("Switching free cloud models preserves other selections")
    func switchingFreeCloudModelsPreservesOtherSelections() {
        let custom = ModelConfig(id: "custom-endpoint:my-model", displayName: "My Model")
        let preservedIDs: Set<String> = [
            ModelConfig.appleTranslateID,
            ModelConfig.microsoftTranslateID,
            ModelConfig.foundationModelID,
            ModelConfig.privateCloudModelID,
            custom.id,
            premium.id,
            "removed-model",
        ]
        let result = ModelSelectionPolicy.toggle(
            secondFree,
            enabledIDs: preservedIDs.union([firstFree.id]),
            availableModels: [
                firstFree, secondFree, premium, custom,
                ModelConfig.appleTranslate, ModelConfig.microsoftTranslate,
                ModelConfig.foundationModel, ModelConfig.privateCloudModel,
            ],
            isPro: false
        )

        #expect(result.enabledIDs == preservedIDs.union([secondFree.id]))
        #expect(result.reason == nil)
    }

    @Test("Switching replaces all previously selected free cloud models")
    func switchingReplacesMultipleFreeCloudModels() {
        let result = ModelSelectionPolicy.toggle(
            thirdFree,
            enabledIDs: [firstFree.id, secondFree.id],
            availableModels: [firstFree, secondFree, thirdFree],
            isPro: false
        )

        #expect(result.enabledIDs == [thirdFree.id])
        #expect(result.reason == nil)
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
        let microsoftResult = ModelSelectionPolicy.toggle(
            ModelConfig.microsoftTranslate,
            enabledIDs: [firstFree.id],
            availableModels: [firstFree, secondFree, ModelConfig.microsoftTranslate],
            isPro: false
        )

        #expect(microsoftResult.enabledIDs == [firstFree.id, ModelConfig.microsoftTranslateID])
        #expect(microsoftResult.reason == nil)

        let appleResult = ModelSelectionPolicy.toggle(
            ModelConfig.appleTranslate,
            enabledIDs: microsoftResult.enabledIDs,
            availableModels: [firstFree, secondFree, ModelConfig.microsoftTranslate, ModelConfig.appleTranslate],
            isPro: false
        )

        let expectedIDs = Set([firstFree.id, ModelConfig.microsoftTranslateID, ModelConfig.appleTranslateID])
        #expect(appleResult.enabledIDs == expectedIDs)
        #expect(appleResult.reason == nil)
    }

    @Test("Foundation Model does not count toward the free cloud model limit")
    func foundationModelDoesNotCountTowardFreeLimit() {
        let result = ModelSelectionPolicy.toggle(
            ModelConfig.foundationModel,
            enabledIDs: [firstFree.id],
            availableModels: [firstFree, secondFree, ModelConfig.foundationModel],
            isPro: false
        )

        #expect(result.enabledIDs == [firstFree.id, ModelConfig.foundationModelID])
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
                ModelConfig.microsoftTranslateID,
                ModelConfig.foundationModelID,
                secondFree.id,
            ],
            availableModels: [
                firstFree,
                ModelConfig.appleTranslate,
                ModelConfig.microsoftTranslate,
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

    @Test("Lapsed members keep a built-in translator and fall back to the default free model")
    func lapsedMemberWithBuiltInAndPremiumFallsBackToDefaultFreeModel() {
        let effective = ModelSelectionPolicy.effectiveEnabledIDs(
            enabledIDs: [ModelConfig.microsoftTranslateID, premium.id],
            availableModels: [secondFree, firstFree, premium, ModelConfig.microsoftTranslate],
            isPro: false
        )

        #expect(effective == [ModelConfig.microsoftTranslateID, firstFree.id])
    }

    @Test("Lapsed members with only a premium model fall back to the default free model")
    func lapsedMemberWithOnlyPremiumFallsBackToDefaultFreeModel() {
        let effective = ModelSelectionPolicy.effectiveEnabledIDs(
            enabledIDs: [premium.id],
            availableModels: [secondFree, firstFree, premium],
            isPro: false
        )
        let withoutDefault = ModelSelectionPolicy.effectiveEnabledIDs(
            enabledIDs: [premium.id],
            availableModels: [secondFree, thirdFree, premium],
            isPro: false
        )

        #expect(effective == [firstFree.id])
        #expect(withoutDefault == [secondFree.id])
    }

    @Test("Non-members keep one free cloud model, preferring the default")
    func nonMembersKeepOneFreeCloudModel() {
        let catalog = [secondFree, firstFree, thirdFree]

        #expect(ModelSelectionPolicy.effectiveEnabledIDs(
            enabledIDs: [secondFree.id, firstFree.id, thirdFree.id], availableModels: catalog, isPro: false
        ) == [firstFree.id])
        #expect(ModelSelectionPolicy.effectiveEnabledIDs(
            enabledIDs: [thirdFree.id, secondFree.id], availableModels: catalog, isPro: false
        ) == [secondFree.id])
    }

    @Test("Built-in selections never gain an AI model")
    func builtInSelectionsNeverGainAIModel() {
        let custom = ModelConfig(id: "custom-endpoint:my-model", displayName: "My Model")
        let stored: Set<String> = [
            ModelConfig.appleTranslateID,
            ModelConfig.microsoftTranslateID,
            ModelConfig.foundationModelID,
            ModelConfig.privateCloudModelID,
            custom.id,
        ]
        let effective = ModelSelectionPolicy.effectiveEnabledIDs(
            enabledIDs: stored,
            availableModels: [firstFree, premium, custom],
            isPro: false
        )

        #expect(effective == stored)
    }

    @Test("Members keep the stored selection unchanged")
    func membersKeepStoredSelection() {
        let stored: Set<String> = [firstFree.id, secondFree.id, premium.id, ModelConfig.microsoftTranslateID]
        let effective = ModelSelectionPolicy.effectiveEnabledIDs(
            enabledIDs: stored,
            availableModels: [firstFree, secondFree, premium],
            isPro: true
        )

        #expect(effective == stored)
    }

    @Test("Toggling for a lapsed member keeps locked premium selections")
    func togglingKeepsLockedPremiumSelections() {
        let result = ModelSelectionPolicy.toggle(
            secondFree,
            enabledIDs: [premium.id],
            availableModels: [firstFree, secondFree, premium],
            isPro: false
        )

        #expect(result.enabledIDs == [premium.id, secondFree.id])
        #expect(result.reason == nil)
    }

    @Test("The last-model guard ignores locked premium selections")
    func lastModelGuardIgnoresLockedPremiumSelections() {
        let result = ModelSelectionPolicy.toggle(
            firstFree,
            enabledIDs: [premium.id],
            availableModels: [firstFree, secondFree, premium],
            isPro: false
        )

        #expect(result.enabledIDs == [premium.id, firstFree.id])
        #expect(result.reason == .keptDefaultModel)
    }

    @Test("A lapsed member can deselect the last AI model while a built-in translator stays")
    func lapsedMemberCanDeselectLastAIModel() {
        let catalog = [firstFree, secondFree, premium]
        let fallback = ModelSelectionPolicy.toggle(
            firstFree,
            enabledIDs: [ModelConfig.microsoftTranslateID, premium.id],
            availableModels: catalog,
            isPro: false
        )
        let chosen = ModelSelectionPolicy.toggle(
            secondFree,
            enabledIDs: [ModelConfig.microsoftTranslateID, premium.id, secondFree.id],
            availableModels: catalog,
            isPro: false
        )

        #expect(fallback.enabledIDs == [ModelConfig.microsoftTranslateID])
        #expect(chosen.enabledIDs == [ModelConfig.microsoftTranslateID])
        #expect(fallback.reason == nil)
    }

    @Test("Callable cloud selection falls back to the free model for lapsed members")
    func callableCloudSelectionFallsBackForLapsedMembers() {
        let selected = ModelSelectionPolicy.firstCallableCloudModelID(
            enabledIDs: [ModelConfig.microsoftTranslateID, premium.id],
            availableModels: [premium, firstFree, ModelConfig.microsoftTranslate],
            isPro: false
        )
        let builtInsOnly = ModelSelectionPolicy.firstCallableCloudModelID(
            enabledIDs: [ModelConfig.microsoftTranslateID],
            availableModels: [premium, firstFree, ModelConfig.microsoftTranslate],
            isPro: false
        )

        #expect(selected == firstFree.id)
        #expect(builtInsOnly == nil)
    }

    @Test("First run enables Microsoft Translate and the first free AI model")
    func firstRunDefaultsUseFirstFreeAIModel() {
        let catalog = [premium, secondFree, firstFree, ModelConfig.microsoftTranslate]
        #expect(ModelConfig.defaultEnabledModelIDs(cloudModels: catalog) == [secondFree.id, ModelConfig.microsoftTranslateID])
        #expect(ModelConfig.defaultEnabledModelIDs(cloudModels: [premium]) == [ModelConfig.microsoftTranslateID])
    }
}
