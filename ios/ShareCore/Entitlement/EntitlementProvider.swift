//
//  EntitlementProvider.swift
//  ShareCore
//
//  Unified entitlement abstraction. The app reads `Entitlement.shared.isPro`
//  without caring whether the underlying source is StoreKit (App Store build)
//  or a web subscription (Direct build).
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
        appStoreTierName: nil,
        hasWebsiteEntitlement: false
    )

    public var isPro: Bool { state.isPro }
    public var expiresAt: Date? { state.expiresAt }

    private var cancellables: Set<AnyCancellable> = []
    private var appStoreIsPro = false
    private var appStoreTierName: String?
    private var websiteIsPro = false
    private var websiteTierName: String?
    private var websiteExpiresAt: Date?

    private init() {
        // ShareCore is compiled once for both targets; switch sources at runtime
        // via the Info.plist channel marker since `#if DIRECT_DISTRIBUTION` is
        // always false inside the framework.
        let direct = BuildEnvironment.isDirectDistribution
        logger.info("init – channel=\(direct ? "direct" : "appstore", privacy: .public)")
        if direct {
            bindWeb()
        } else {
            bindAppStore()
        }
    }

    /// Force a refresh against the underlying source.
    public func refresh() async {
        if BuildEnvironment.isDirectDistribution {
            let provider = WebEntitlementProvider.shared
            await provider.refresh()
            syncWebsiteState(from: provider)
        } else {
            let store = StoreManager.shared
            let provider = WebEntitlementProvider.shared
            if OAuthTokenStore.load() != nil {
                async let storeRefresh: Void = store.refreshSubscriptionStatus()
                async let webRefresh: Void = provider.refresh()
                _ = await (storeRefresh, webRefresh)
            } else {
                await store.refreshSubscriptionStatus()
            }
            appStoreIsPro = store.isPremium
            appStoreTierName = appStoreTierName(from: store)
            syncWebsiteState(from: provider)
        }
        publishCurrentState()
    }

    @discardableResult
    public func refreshAndGetIsPro() async -> Bool {
        await refresh()
        return isPro
    }

    private func bindWeb() {
        let provider = WebEntitlementProvider.shared
        syncWebsiteState(from: provider)
        publishCurrentState()
        logger.info("bindWeb – initial isPro=\(self.isPro, privacy: .public)")
        provider.$isPro
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                logger.info("bindWeb – isPro changed -> \($0, privacy: .public)")
                self?.websiteIsPro = $0
                self?.publishCurrentState()
            }
            .store(in: &cancellables)
        provider.$expiresAt
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.websiteExpiresAt = $0
                self?.publishCurrentState()
            }
            .store(in: &cancellables)
        provider.$plan
            .receive(on: RunLoop.main)
            .sink { [weak self] plan in
                self?.websiteTierName = plan.flatMap { PremiumProduct.tierDisplayName(forWebsitePlan: $0) }
                self?.publishCurrentState()
            }
            .store(in: &cancellables)
    }

    private func bindAppStore() {
        let store = StoreManager.shared
        let provider = WebEntitlementProvider.shared
        appStoreIsPro = store.isPremium
        appStoreTierName = appStoreTierName(from: store)
        syncWebsiteState(from: provider)
        publishCurrentState()
        logger.info("bindAppStore – initial isPro=\(self.isPro, privacy: .public)")
        store.$isPremium
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                logger.info("bindAppStore – isPremium changed -> \($0, privacy: .public)")
                self?.appStoreIsPro = $0
                self?.appStoreTierName = self?.appStoreTierName(from: store)
                self?.publishCurrentState()
            }
            .store(in: &cancellables)
        Publishers.Merge(store.$activePremiumProductID, store.$premiumSourceDisplayName)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.appStoreTierName = self?.appStoreTierName(from: store)
                self?.publishCurrentState()
            }
            .store(in: &cancellables)
        provider.$isPro
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                logger.info("bindAppStore – website isPro changed -> \($0, privacy: .public)")
                self?.websiteIsPro = $0
                self?.publishCurrentState()
            }
            .store(in: &cancellables)
        provider.$expiresAt
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.websiteExpiresAt = $0
                self?.publishCurrentState()
            }
            .store(in: &cancellables)
        provider.$plan
            .receive(on: RunLoop.main)
            .sink { [weak self] plan in
                self?.websiteTierName = plan.flatMap { PremiumProduct.tierDisplayName(forWebsitePlan: $0) }
                self?.publishCurrentState()
            }
            .store(in: &cancellables)
    }

    private func syncWebsiteState(from provider: WebEntitlementProvider) {
        websiteIsPro = provider.isPro
        websiteTierName = provider.plan.flatMap { PremiumProduct.tierDisplayName(forWebsitePlan: $0) }
        websiteExpiresAt = provider.expiresAt
    }

    private func appStoreTierName(from store: StoreManager) -> String? {
        store.activePremiumProductID.flatMap { PremiumProduct.tierDisplayName(for: $0) } ?? store.premiumSourceDisplayName
    }

    private func publishCurrentState() {
        let next = EntitlementState(
            hasAppStoreEntitlement: appStoreIsPro,
            appStoreTierName: appStoreTierName,
            hasWebsiteEntitlement: websiteIsPro,
            websiteTierName: websiteTierName,
            expiresAt: websiteExpiresAt
        )
        guard state != next else { return }
        state = next
    }
}
