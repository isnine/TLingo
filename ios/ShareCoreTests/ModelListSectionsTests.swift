//
//  ModelListSectionsTests.swift
//  ShareCoreTests
//

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

    @Test("Hidden free model is collapsed when disabled")
    func hiddenFreeModelIsCollapsedWhenDisabled() {
        let sections = ModelListSections(cloudModels: [hiddenFree], enabledIDs: [])

        #expect(sections.visibleFreeModels.isEmpty)
        #expect(sections.collapsedFreeModels == [hiddenFree])
    }

    @Test("Hidden free model is visible when enabled")
    func hiddenFreeModelIsVisibleWhenEnabled() {
        let sections = ModelListSections(cloudModels: [hiddenFree], enabledIDs: [hiddenFree.id])

        #expect(sections.visibleFreeModels == [hiddenFree])
        #expect(sections.collapsedFreeModels.isEmpty)
    }

    @Test("Hidden premium model is collapsed when disabled")
    func hiddenPremiumModelIsCollapsedWhenDisabled() {
        let sections = ModelListSections(cloudModels: [hiddenPremium], enabledIDs: [])

        #expect(sections.visiblePremiumModels.isEmpty)
        #expect(sections.collapsedPremiumModels == [hiddenPremium])
    }

    @Test("Free and premium models stay in separate sections")
    func freeAndPremiumModelsStayInSeparateSections() {
        let sections = ModelListSections(
            cloudModels: [visibleFree, hiddenFree, visiblePremium, hiddenPremium],
            enabledIDs: []
        )

        #expect(sections.visibleFreeModels == [visibleFree])
        #expect(sections.collapsedFreeModels == [hiddenFree])
        #expect(sections.visiblePremiumModels == [visiblePremium])
        #expect(sections.collapsedPremiumModels == [hiddenPremium])
    }

    @Test("Empty model list returns empty sections")
    func emptyModelListReturnsEmptySections() {
        let sections = ModelListSections(cloudModels: [], enabledIDs: [])

        #expect(sections.visibleFreeModels.isEmpty)
        #expect(sections.collapsedFreeModels.isEmpty)
        #expect(sections.visiblePremiumModels.isEmpty)
        #expect(sections.collapsedPremiumModels.isEmpty)
    }
}
