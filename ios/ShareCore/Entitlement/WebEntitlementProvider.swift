//
//  WebEntitlementProvider.swift
//  ShareCore
//
//  Website entitlement source. Direct builds use it as the primary entitlement
//  source; App Store builds use it only for restored website purchases. After
//  the OAuth migration this is a thin observable surface that OAuth flows push
//  into; it no longer talks to Supabase Auth or holds a Supabase session.
//
//  Cache key namespace: "entitlement.web.*" (UserDefaults).
//

import Combine
import Foundation
import os

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "WebEntitlement")

@MainActor
public final class WebEntitlementProvider: ObservableObject {
    public static let shared = WebEntitlementProvider()

    @Published public private(set) var isPro: Bool = false
    @Published public private(set) var expiresAt: Date?
    @Published public private(set) var email: String?
    @Published public private(set) var plan: String?

    public var isProPublisher: AnyPublisher<Bool, Never> {
        $isPro.eraseToAnyPublisher()
    }

    /// 7-day offline grace period. Used when restoring `isPro=true` from
    /// the cache on launch (when OAuth tokens haven't been refreshed yet).
    public nonisolated static let offlineGrace: TimeInterval = 7 * 24 * 3600

    private static let cacheKeyIsPro = "entitlement.web.isPro"
    private static let cacheKeyExpires = "entitlement.web.expiresAt"
    private static let cacheKeyCachedAt = "entitlement.web.cachedAt"
    private static let cacheKeyEmail = "entitlement.web.email"
    private static let cacheKeyPlan = "entitlement.web.plan"

    private init() {
        guard !SnapshotLaunchArguments.isSnapshotMode() else { return }
        // OAuth tokens are the source of truth. Mirror the cached entitlement
        // immediately on launch so the UI shows Pro before the network
        // refresh completes; the actual refresh happens via
        // OAuthCoordinator.refreshIfStale(maxAge:reason:) in RootTabView.task.
        if let oauth = OAuthTokenStore.load() {
            logger.info("init – OAuth tokens present, mirroring entitlement")
            applyOAuthEntitlement(
                isPremium: oauth.isPremium && (oauth.entitlementExpiresAt.map { $0 > Date() } ?? true),
                plan: oauth.plan,
                expiresAt: oauth.entitlementExpiresAt,
                email: oauth.email
            )
        } else {
            hydrateFromCache()
        }
    }

    // MARK: - OAuth bridge

    /// Apply an OAuth activation result. Pass `nil` on sign-out / clear.
    /// No-op when the incoming `(isPremium, expiresAt)` matches the
    /// current state — avoids gratuitous SwiftUI invalidations and disk
    /// writes when the periodic refresh ticker reports unchanged status.
    public func applyOAuthEntitlement(isPremium: Bool, plan: String?, expiresAt: Date?, email: String? = nil) {
        let isWithinCurrentMembership = isPro && expiresAt.map { $0 > Date() } == true
        let effectiveIsPremium = isPremium || isWithinCurrentMembership
        if isPro == effectiveIsPremium, self.expiresAt == expiresAt, self.email == email, self.plan == plan {
            return
        }
        logger.info(
            """
            applyOAuthEntitlement – isPremium=\(effectiveIsPremium, privacy: .public) \
            plan=\(plan ?? "nil", privacy: .public)
            """
        )
        isPro = effectiveIsPremium
        self.expiresAt = expiresAt
        self.email = email
        self.plan = plan
        let defaults = AppPreferences.sharedDefaults
        defaults.set(effectiveIsPremium, forKey: Self.cacheKeyIsPro)
        defaults.set(expiresAt, forKey: Self.cacheKeyExpires)
        if let email {
            defaults.set(email, forKey: Self.cacheKeyEmail)
        } else {
            defaults.removeObject(forKey: Self.cacheKeyEmail)
        }
        if let plan {
            defaults.set(plan, forKey: Self.cacheKeyPlan)
        } else {
            defaults.removeObject(forKey: Self.cacheKeyPlan)
        }
        defaults.set(Date(), forKey: Self.cacheKeyCachedAt)
        if BuildEnvironment.isDirectDistribution {
            AppPreferences.shared.setIsPremium(effectiveIsPremium)
        }
        // Sign-in / sign-out can flip developer mode; refresh the network
        // logger gate so subsequent requests are (un)recorded immediately.
        DebugNetworkProtocol.refreshLoggingEnabled()
    }

    public func clearOAuthEntitlement() {
        logger.info("clearOAuthEntitlement – resetting cached premium state")
        isPro = false
        expiresAt = nil
        email = nil
        plan = nil
        clearCachedEntitlement()
        if BuildEnvironment.isDirectDistribution {
            AppPreferences.shared.setIsPremium(false)
        }
        DebugNetworkProtocol.refreshLoggingEnabled()
    }

    // MARK: - Refresh

    /// Force a network refresh; bypasses `refreshIfNeeded`'s stale-token
    /// short-circuit so user-initiated and post-purchase callers always
    /// observe the new entitlement.
    public func refresh() async {
        _ = await OAuthCoordinator.shared.refreshIfNeeded(force: true)
    }

    // MARK: - Cache

    private func hydrateFromCache() {
        let defaults = AppPreferences.sharedDefaults
        let cachedIsPro = defaults.bool(forKey: Self.cacheKeyIsPro)
        let cachedAt = defaults.object(forKey: Self.cacheKeyCachedAt) as? Date
        let expires = defaults.object(forKey: Self.cacheKeyExpires) as? Date

        // The main app must not trust cached premium without OAuth tokens.
        // The iOS extension cannot read the app's keychain row, so it may use
        // the shared App Group cache for a bounded grace period.
        if cachedIsPro {
            guard WebEntitlementCachePolicy.canHydrateCachedPremium(
                cachedAt: cachedAt,
                hasOAuthTokens: false,
                isAppExtension: Self.isAppExtension
            ) else {
                logger.warning("hydrate – discarding cached isPro=true: no trusted OAuth tokens or fresh extension cache")
                clearCachedEntitlement()
                return
            }

            logger.info("hydrate – using fresh shared website entitlement cache in extension")
            isPro = true
            expiresAt = expires
            email = defaults.string(forKey: Self.cacheKeyEmail)
            plan = defaults.string(forKey: Self.cacheKeyPlan)
        } else {
            logger.debug("hydrate – no tokens, no cached isPro; staying false")
        }
    }

    private func clearCachedEntitlement() {
        let defaults = AppPreferences.sharedDefaults
        defaults.removeObject(forKey: Self.cacheKeyIsPro)
        defaults.removeObject(forKey: Self.cacheKeyExpires)
        defaults.removeObject(forKey: Self.cacheKeyCachedAt)
        defaults.removeObject(forKey: Self.cacheKeyEmail)
        defaults.removeObject(forKey: Self.cacheKeyPlan)
    }

    private static var isAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }
}

enum WebEntitlementCachePolicy {
    static func canHydrateCachedPremium(
        cachedAt: Date?,
        now: Date = Date(),
        hasOAuthTokens: Bool,
        isAppExtension: Bool,
        offlineGrace: TimeInterval = WebEntitlementProvider.offlineGrace
    ) -> Bool {
        if hasOAuthTokens { return true }
        guard isAppExtension, let cachedAt else { return false }
        let age = now.timeIntervalSince(cachedAt)
        return age >= 0 && age <= offlineGrace
    }
}
