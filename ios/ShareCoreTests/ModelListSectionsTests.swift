//
//  ModelListSectionsTests.swift
//  ShareCoreTests
//

import Foundation
import ShareCore
import Testing

struct ModelListSectionsTests {
    private let visibleFree = ModelConfig(id: "free-visible", displayName: "Free Visible")
    private let hiddenFree = ModelConfig(id: "free-hidden", displayName: "Free Hidden", hidden: true)
    private let visiblePremium = ModelConfig(id: "premium-visible", displayName: "Premium Visible", isPremium: true)
    private let hiddenPremium = ModelConfig(
        id: "premium-hidden",
        displayName: "Premium Hidden",
        isPremium: true,
        hidden: true
    )

    @Test("Hidden model is collapsed when disabled")
    func hiddenModelIsCollapsedWhenDisabled() {
        let sections = ModelListSections(cloudModels: [hiddenFree], enabledIDs: [], isPro: false)

        #expect(sections.visibleModels.isEmpty)
        #expect(sections.collapsedModels == [hiddenFree])
    }

    @Test("Hidden model is visible when enabled")
    func hiddenModelIsVisibleWhenEnabled() {
        let sections = ModelListSections(cloudModels: [hiddenFree], enabledIDs: [hiddenFree.id], isPro: false)

        #expect(sections.visibleModels == [hiddenFree])
        #expect(sections.collapsedModels.isEmpty)
    }

    @Test("Membership decides whether free or premium models lead the AI section")
    func membershipDecidesDefaultAIOrder() {
        let models = [visiblePremium, visibleFree, hiddenPremium, hiddenFree]
        let free = ModelListSections(cloudModels: models, enabledIDs: [], isPro: false)
        #expect(free.visibleModels == [visibleFree, visiblePremium])
        #expect(free.collapsedModels == [hiddenFree, hiddenPremium])
        let pro = ModelListSections(cloudModels: models, enabledIDs: [], isPro: true)
        #expect(pro.visibleModels == [visiblePremium, visibleFree])
        #expect(pro.collapsedModels == [hiddenPremium, hiddenFree])
    }

    @Test("Custom ordering overrides membership and keeps hidden-model visibility rules")
    func customOrderKeepsHiddenModelsCollapsedUntilEnabled() {
        var order = ModelListOrder()
        order.modelIDsBySection[ModelListSection.ai.rawValue] = [hiddenFree.id, visibleFree.id, visiblePremium.id]
        let collapsed = ModelListSections(
            cloudModels: [visiblePremium, visibleFree, hiddenFree], enabledIDs: [], order: order, isPro: true
        )
        #expect(collapsed.visibleModels == [visibleFree, visiblePremium])
        #expect(collapsed.collapsedModels == [hiddenFree])
        let enabled = ModelListSections(
            cloudModels: [visiblePremium, visibleFree, hiddenFree], enabledIDs: [hiddenFree.id], order: order, isPro: true
        )
        #expect(enabled.visibleModels == [hiddenFree, visibleFree, visiblePremium])
        #expect(enabled.collapsedModels.isEmpty)
    }

    @Test("Legacy free and premium orders migrate into the AI section")
    func legacyOrderMigratesIntoAISection() throws {
        let json = """
        {"sections":["premium","translation","free","appleIntelligence"],
         "modelIDsBySection":{"free":["f2","f1"],"premium":["p1"],"translation":["microsoft"]}}
        """
        let order = try JSONDecoder().decode(ModelListOrder.self, from: Data(json.utf8))
        #expect(order.sections == [.ai, .translation, .appleIntelligence])
        #expect(order.modelIDsBySection == ["ai": ["p1", "f2", "f1"], "translation": ["microsoft"]])
        let untouched = """
        {"sections":["translation","free","premium","appleIntelligence"],"modelIDsBySection":{}}
        """
        #expect(try JSONDecoder().decode(ModelListOrder.self, from: Data(untouched.utf8)) == ModelListOrder())
    }
}
