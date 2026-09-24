//
//  ModelListSections.swift
//  ShareCore
//

import Foundation

public struct ModelListSections: Sendable {
    public static func resultOrder(cloudModels: [ModelConfig]) -> [ModelConfig] {
        ModelConfig.translationServices
            + ModelConfig.appleIntelligenceModels
            + cloudModels.filter { !$0.isPremium }
            + cloudModels.filter(\.isPremium)
    }

    public let visibleFreeModels: [ModelConfig]
    public let collapsedFreeModels: [ModelConfig]
    public let visiblePremiumModels: [ModelConfig]
    public let collapsedPremiumModels: [ModelConfig]

    public init(cloudModels: [ModelConfig], enabledIDs: Set<String>) {
        var visibleFreeModels: [ModelConfig] = []
        var collapsedFreeModels: [ModelConfig] = []
        var visiblePremiumModels: [ModelConfig] = []
        var collapsedPremiumModels: [ModelConfig] = []

        for model in cloudModels {
            let isVisible = !model.hidden || enabledIDs.contains(model.id)
            if model.isPremium {
                if isVisible {
                    visiblePremiumModels.append(model)
                } else {
                    collapsedPremiumModels.append(model)
                }
            } else if isVisible {
                visibleFreeModels.append(model)
            } else {
                collapsedFreeModels.append(model)
            }
        }

        self.visibleFreeModels = visibleFreeModels
        self.collapsedFreeModels = collapsedFreeModels
        self.visiblePremiumModels = visiblePremiumModels
        self.collapsedPremiumModels = collapsedPremiumModels
    }
}
