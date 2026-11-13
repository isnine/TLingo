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
        guard !model.isPremium || isPro else {
            return ToggleResult(enabledIDs: enabledIDs, reason: .requiresPro)
        }

        // Edit what is actually usable, then add back the locked premium selections
        // so they come back when the subscription is restored.
        let current = effectiveEnabledIDs(enabledIDs: enabledIDs, availableModels: availableModels, isPro: isPro)
        let lockedIDs = enabledIDs.subtracting(current).intersection(premiumIDs(in: availableModels))

        if current.contains(model.id) {
            let result = disabling(model, enabledIDs: current, availableModels: availableModels, isPro: isPro)
            let stored = result.enabledIDs.union(lockedIDs)
            // With no cloud model left, locked selections would bring a fallback model straight
            // back, so an explicit deselect forgets them.
            let effective = effectiveEnabledIDs(enabledIDs: stored, availableModels: availableModels, isPro: isPro)
            if result.reason == nil, effective != result.enabledIDs {
                return ToggleResult(enabledIDs: result.enabledIDs)
            }
            return ToggleResult(enabledIDs: stored, reason: result.reason)
        }

        var updated = current
        if !isPro, model.isCloudModel {
            let freeCloudIDs = availableModels
                .filter { !$0.isPremium && $0.isCloudModel }
                .map(\.id)
            updated.subtract(freeCloudIDs)
        }
        updated.insert(model.id)

        return ToggleResult(enabledIDs: updated.union(lockedIDs))
    }

    /// The part of the stored selection that can run right now. Storage is never modified, so
    /// premium selections survive a lapsed subscription.
    ///
    /// Without Pro, premium models are dropped and at most one free cloud model stays. When the
    /// user had chosen cloud models but none is left, the default free one replaces them; a
    /// selection of direct translators only never gains an AI model.
    public static func effectiveEnabledIDs(
        enabledIDs: Set<String>,
        availableModels: [ModelConfig],
        isPro: Bool
    ) -> Set<String> {
        guard !isPro else { return enabledIDs }

        let storedCloudModels = availableModels.filter { $0.isCloudModel && enabledIDs.contains($0.id) }
        let storedFreeCloudModels = storedCloudModels.filter { !$0.isPremium }

        var effective = enabledIDs.subtracting(premiumIDs(in: availableModels))
        effective.subtract(storedFreeCloudModels.map(\.id))
        if let kept = storedFreeCloudModels.first(where: \.isDefault) ?? storedFreeCloudModels.first {
            effective.insert(kept.id)
        } else if !storedCloudModels.isEmpty, let fallback = defaultFreeCloudModel(in: availableModels) {
            effective.insert(fallback.id)
        }
        return effective
    }

    public static func firstCallableCloudModelID(
        enabledIDs: Set<String>,
        availableModels: [ModelConfig],
        isPro: Bool
    ) -> String? {
        let effectiveIDs = effectiveEnabledIDs(enabledIDs: enabledIDs, availableModels: availableModels, isPro: isPro)
        return availableModels.first {
            effectiveIDs.contains($0.id)
                && $0.isCloudModel
                && (isPro || !$0.isPremium)
        }?.id
    }

    private static func premiumIDs(in availableModels: [ModelConfig]) -> Set<String> {
        Set(availableModels.filter(\.isPremium).map(\.id))
    }

    private static func defaultFreeCloudModel(in availableModels: [ModelConfig]) -> ModelConfig? {
        availableModels.first { $0.isDefault && $0.isCloudModel && !$0.isPremium }
            ?? ModelConfig.firstFreeCloudModel(in: availableModels)
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
