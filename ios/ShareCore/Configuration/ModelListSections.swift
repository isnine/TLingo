//
//  ModelListSections.swift
//  ShareCore
//

import Foundation

public enum ModelListSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case ai
    case translation
    case appleIntelligence

    public var id: String {
        rawValue
    }
}

public struct ModelListOrder: Codable, Equatable, Sendable {
    public var sections: [ModelListSection] = ModelListSection.allCases
    public var modelIDsBySection: [String: [String]] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case sections
        case modelIDsBySection
    }

    /// Orders saved before free and premium models shared one AI section stored them as
    /// `free` and `premium`; their saved model orders are joined in the user's group order.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSections = try container.decode([String].self, forKey: .sections)
        var idsBySection = try container.decode([String: [String]].self, forKey: .modelIDsBySection)
        let legacyAISections = ["free", "premium"]
        let legacyIDs = (rawSections + legacyAISections)
            .filter { legacyAISections.contains($0) }
            .compactMap { idsBySection.removeValue(forKey: $0) }
        if !legacyIDs.isEmpty, idsBySection[ModelListSection.ai.rawValue] == nil {
            idsBySection[ModelListSection.ai.rawValue] = legacyIDs.flatMap(\.self)
        }
        var seen = Set<ModelListSection>()
        sections = rawSections
            .compactMap { legacyAISections.contains($0) ? .ai : ModelListSection(rawValue: $0) }
            .filter { seen.insert($0).inserted }
        modelIDsBySection = idsBySection
    }

    public var orderedSections: [ModelListSection] {
        var seen = Set<ModelListSection>()
        return (sections + ModelListSection.allCases).filter { seen.insert($0).inserted }
    }

    /// Until the user saves an AI model order, members see premium models first and
    /// everyone else sees free models first.
    public func models(in section: ModelListSection, cloudModels: [ModelConfig], isPro: Bool) -> [ModelConfig] {
        let models: [ModelConfig]
        switch section {
        case .translation:
            models = ModelConfig.translationServices
        case .appleIntelligence:
            models = ModelConfig.appleIntelligenceModels
        case .ai:
            let aiModels = cloudModels.filter { !$0.isDirectTranslation && !$0.isFoundationModel }
            models = aiModels.filter { $0.isPremium == isPro } + aiModels.filter { $0.isPremium != isPro }
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
    public static func resultOrder(
        cloudModels: [ModelConfig],
        order: ModelListOrder = .init(),
        isPro: Bool
    ) -> [ModelConfig] {
        order.orderedSections.flatMap { order.models(in: $0, cloudModels: cloudModels, isPro: isPro) }
    }

    public let visibleModels: [ModelConfig]
    public let collapsedModels: [ModelConfig]

    public init(cloudModels: [ModelConfig], enabledIDs: Set<String>, order: ModelListOrder = .init(), isPro: Bool) {
        let models = order.models(in: .ai, cloudModels: cloudModels, isPro: isPro)
        let isVisible = { (model: ModelConfig) in !model.hidden || enabledIDs.contains(model.id) }
        visibleModels = models.filter(isVisible)
        collapsedModels = models.filter { !isVisible($0) }
    }
}
