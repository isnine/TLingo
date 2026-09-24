//
//  ModelSelectionPolicy.swift
//  ShareCore
//

import Foundation

public enum ModelSelectionPolicy {
    public static let freeCloudModelLimit = 1

    public enum Reason: Equatable {
        case freeCloudModelLimitReached
        case requiresPro
        case keptDefaultModel
    }

    public struct ToggleResult: Equatable {
        public let enabledIDs: Set<String>
        public let reason: Reason?

        public init(enabledIDs: Set<String>, reason: Reason? = nil) {
            self.enabledIDs = enabledIDs
            self.reason = reason
        }
    }

    public static func toggle(
        _ model: ModelConfig,
        enabledIDs: Set<String>,
        availableModels: [ModelConfig],
        isPro: Bool
    ) -> ToggleResult {
        if enabledIDs.contains(model.id) {
            return disabling(model, enabledIDs: enabledIDs, availableModels: availableModels, isPro: isPro)
        }

        guard !model.isPremium || isPro else {
            return ToggleResult(enabledIDs: enabledIDs, reason: .requiresPro)
        }

        var updated = enabledIDs
        updated.insert(model.id)

        let wouldExceedFreeLimit = !isPro
            && model.isCloudModel
            && freeCloudModelCount(in: updated, availableModels: availableModels) > freeCloudModelLimit

        if wouldExceedFreeLimit {
            return ToggleResult(enabledIDs: enabledIDs, reason: .freeCloudModelLimitReached)
        }

        return ToggleResult(enabledIDs: updated)
    }

    public static func freeCloudModelCount(
        in enabledIDs: Set<String>,
        availableModels: [ModelConfig]
    ) -> Int {
        availableModels
            .filter { enabledIDs.contains($0.id) }
            .filter { !$0.isPremium && $0.isCloudModel }
            .count
    }

    public static func firstCallableCloudModelID(
        enabledIDs: Set<String>,
        availableModels: [ModelConfig],
        isPro: Bool
    ) -> String? {
        availableModels.first {
            enabledIDs.contains($0.id)
                && $0.isCloudModel
                && (isPro || !$0.isPremium)
        }?.id
    }

    private static func fallbackEnabledIDs(
        availableModels: [ModelConfig],
        isPro: Bool
    ) -> Set<String> {
        guard let fallback = defaultAccessibleModel(availableModels: availableModels, isPro: isPro) else {
            return []
        }
        return [fallback.id]
    }

    private static func disabling(
        _ model: ModelConfig,
        enabledIDs: Set<String>,
        availableModels: [ModelConfig],
        isPro: Bool
    ) -> ToggleResult {
        var updated = enabledIDs
        updated.remove(model.id)

        guard updated.isEmpty else {
            return ToggleResult(enabledIDs: updated)
        }

        let fallback = fallbackEnabledIDs(availableModels: availableModels, isPro: isPro)
        if fallback.isEmpty {
            return ToggleResult(enabledIDs: updated)
        }
        return ToggleResult(enabledIDs: fallback, reason: .keptDefaultModel)
    }

    private static func defaultAccessibleModel(
        availableModels: [ModelConfig],
        isPro: Bool
    ) -> ModelConfig? {
        let accessibleModels = availableModels.filter { isPro || !$0.isPremium }
        return accessibleModels.first(where: \.isDefault) ?? accessibleModels.first
    }
}
