//
//  EntitlementProvider.swift
//  ShareCore
//
//  Unified entitlement abstraction backed by StoreKit. The app reads
//  `Entitlement.shared.isPro` without touching `StoreManager` directly.
//
//  Implemented as an `ObservableObject` so SwiftUI views can observe changes
//  via `@ObservedObject`.
//

import Combine
import Foundation
import os

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "Entitlement")

@MainActor
public final class Entitlement: ObservableObject {
    public static let shared = Entitlement()

    @Published public private(set) var state = EntitlementState(
        hasAppStoreEntitlement: false,
        appStoreTierName: nil
    )

    public var isPro: Bool { state.isPro }

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let store = StoreManager.shared
        publishState(from: store)
        logger.info("init – initial isPro=\(self.isPro, privacy: .public)")
        Publishers.CombineLatest3(store.$isPremium, store.$activePremiumProductID, store.$premiumSourceDisplayName)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.publishState(from: store)
            }
            .store(in: &cancellables)
    }

    /// Force a refresh against StoreKit.
    public func refresh() async {
        let store = StoreManager.shared
        await store.refreshSubscriptionStatus()
        publishState(from: store)
    }

    @discardableResult
    public func refreshAndGetIsPro() async -> Bool {
        await refresh()
        return isPro
    }

    private func publishState(from store: StoreManager) {
        let next = EntitlementState(
            hasAppStoreEntitlement: store.isPremium,
            appStoreTierName: store.activePremiumProductID.flatMap { PremiumProduct.tierDisplayName(for: $0) }
                ?? store.premiumSourceDisplayName
        )
        guard state != next else { return }
        if next.isPro != state.isPro {
            logger.info("isPro changed -> \(next.isPro, privacy: .public)")
        }
        state = next
    }
}
