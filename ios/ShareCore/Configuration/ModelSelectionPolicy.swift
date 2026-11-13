//
//  ModelSelectionPolicy.swift
//  ShareCore
//

import Foundation

public enum ModelSelectionPolicy {
    public enum Reason: Equatable {
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
        // Locked premium selections are kept so they come back when the subscription is restored.
        guard !model.isPremium || isPro else {
            return ToggleResult(enabledIDs: enabledIDs, reason: .requiresPro)
        }

        if enabledIDs.contains(model.id) {
            return disabling(model, enabledIDs: enabledIDs, availableModels: availableModels, isPro: isPro)
        }

        var updated = enabledIDs
        if !isPro, model.isCloudModel {
            let freeCloudIDs = availableModels
                .filter { !$0.isPremium && $0.isCloudModel }
                .map(\.id)
            updated.subtract(freeCloudIDs)
        }
        updated.insert(model.id)

        return ToggleResult(enabledIDs: updated)
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
