//
//  ModelListSections.swift
//  ShareCore
//

import Foundation

public enum ModelListSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case translation
    case appleIntelligence
    case free
    case premium

    public var id: String {
        rawValue
    }
}

public struct ModelListOrder: Codable, Equatable, Sendable {
    public var sections: [ModelListSection] = ModelListSection.allCases
    public var modelIDsBySection: [String: [String]] = [:]

    public init() {}

    public var orderedSections: [ModelListSection] {
        var seen = Set<ModelListSection>()
        return (sections + ModelListSection.allCases).filter { seen.insert($0).inserted }
    }

    public func models(in section: ModelListSection, cloudModels: [ModelConfig]) -> [ModelConfig] {
        let models: [ModelConfig]
        switch section {
        case .translation:
            models = ModelConfig.translationServices
        case .appleIntelligence:
            models = ModelConfig.appleIntelligenceModels
        case .free, .premium:
            models = cloudModels.filter {
                !$0.isDirectTranslation && !$0.isFoundationModel && $0.isPremium == (section == .premium)
            }
        }
        let ranks = Dictionary(
            (modelIDsBySection[section.rawValue] ?? []).enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return models.enumerated().sorted { lhs, rhs in
            let left = ranks[lhs.element.id] ?? Int.max
            let right = ranks[rhs.element.id] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }
}

public struct ModelListSections: Sendable {
    public static func resultOrder(cloudModels: [ModelConfig], order: ModelListOrder = .init()) -> [ModelConfig] {
        order.orderedSections.flatMap { order.models(in: $0, cloudModels: cloudModels) }
    }

    public let visibleFreeModels: [ModelConfig]
    public let collapsedFreeModels: [ModelConfig]
    public let visiblePremiumModels: [ModelConfig]
    public let collapsedPremiumModels: [ModelConfig]

    public init(cloudModels: [ModelConfig], enabledIDs: Set<String>, order: ModelListOrder = .init()) {
        var visibleFreeModels: [ModelConfig] = []
        var collapsedFreeModels: [ModelConfig] = []
        var visiblePremiumModels: [ModelConfig] = []
        var collapsedPremiumModels: [ModelConfig] = []

        let orderedCloudModels = order.models(in: .free, cloudModels: cloudModels)
            + order.models(in: .premium, cloudModels: cloudModels)
        for model in orderedCloudModels {
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
