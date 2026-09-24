//
//  StoreManager.swift
//  ShareCore
//
//  Created by Codex on 2025/02/07.
//

import Combine
import Foundation
import os
import StoreKit

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "StoreManager")

/// Manages StoreKit 2 subscription state and purchasing.
@MainActor
public final class StoreManager: ObservableObject {
    public static let shared = StoreManager()

    // MARK: - Published State

    @Published public private(set) var isPremium: Bool = false
    @Published public private(set) var products: [Product] = []
    @Published public private(set) var purchaseError: String?
    @Published public private(set) var purchaseFailedDeviceVerification: Bool = false
    @Published public private(set) var isLoadingProducts: Bool = false
    @Published public private(set) var isPurchasing: Bool = false
    @Published public private(set) var activePremiumProductID: String?
    @Published public private(set) var premiumSourceDisplayName: String?
    @Published public private(set) var usageAppStoreSubjectID: String?

    // MARK: - Private

    private var transactionListener: Task<Void, Never>?
    private static let premiumKey = "is_premium_subscriber"
    private static let appAccountTokenKey = "storekit_app_account_token"
    private static let usageAppStoreSubjectIDKey = "usage.appstore.subject_id"
    private var webEntitlementCancellable: AnyCancellable?

    /// `true` when running via TestFlight.
    ///
    /// Detection strategy:
    /// - iOS/iPadOS: App Store receipt path contains `sandboxReceipt`.
    /// - macOS: the receipt filename is identical to Mac App Store builds, so we additionally
    ///   check for `/TestFlight/` in the bundle path and fall back to the authoritative
    ///   `AppTransaction` environment probe, whose result is cached after launch.
    public static var isTestFlight: Bool {
        #if DEBUG
            return false
        #else
            if let receiptURL = Bundle.main.appStoreReceiptURL,
               receiptURL.path.contains("sandboxReceipt")
            {
                return true
            }
            #if os(macOS)
                if Bundle.main.bundlePath.contains("/TestFlight/") { return true }
            #endif
            return isTestFlightEnvironmentCached
        #endif
    }

    // Cached because `isTestFlight` must stay synchronous, but the authoritative probe
    // (`AppTransaction`) is async. Written once from the @MainActor init task; the Bool
    // write is atomic on our target architectures.
    private nonisolated(unsafe) static var isTestFlightEnvironmentCached: Bool = false

    /// Whether TestFlight premium override is currently active.
    @Published public private(set) var isTestFlightOverride: Bool = false

    private static let testFlightOverrideKey = "testflight_premium_override"
    private static var isAppExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }

    // MARK: - Init

    private init() {
        // Direct distribution: bridge `isPremium` to `WebEntitlementProvider`.
        // Legacy `is_premium_subscriber` purge happens in `AppPreferences.init`.
        if BuildEnvironment.isDirectDistribution {
            isPremium = WebEntitlementProvider.shared.isPro
            webEntitlementCancellable = WebEntitlementProvider.shared.$isPro
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.isPremium = $0 }
            logger.info("Direct build – StoreKit bypassed, bridged to WebEntitlementProvider")
            return
        }

        #if DEBUG
            // Auto-enable premium in development builds unless user toggled it off
            isTestFlightOverride = AppPreferences.sharedDefaults.bool(forKey: Self.testFlightOverrideKey)
            if isTestFlightOverride {
                isPremium = false
                logger.debug("DEBUG build – premium disabled via override toggle")
            } else {
                isPremium = true
                premiumSourceDisplayName = String(localized: "Debug")
                AppPreferences.sharedDefaults.set(true, forKey: Self.premiumKey)
                logger.debug("DEBUG build – premium auto-enabled")
            }

            transactionListener = listenForTransactions()
            Task {
                await loadProducts()
            }
        #else
            // Read cached premium status from App Group defaults
            isPremium = AppPreferences.sharedDefaults.bool(forKey: Self.premiumKey)
            usageAppStoreSubjectID = AppPreferences.sharedDefaults.string(forKey: Self.usageAppStoreSubjectIDKey)

            // Restore TestFlight override if previously enabled
            if Self.isTestFlight || Self.isAppExtension {
                isTestFlightOverride = AppPreferences.sharedDefaults.bool(forKey: Self.testFlightOverrideKey)
                if isTestFlightOverride {
                    isPremium = true
                    premiumSourceDisplayName = String(localized: "TestFlight")
                    logger.debug("TestFlight override restored – premium enabled")
                }
            } else {
                // Clean up any stale TF override from a previous TestFlight install
                AppPreferences.sharedDefaults.removeObject(forKey: Self.testFlightOverrideKey)
            }

            // Start listening for transaction updates
            transactionListener = listenForTransactions()

            // Check current entitlements on launch
            Task {
                await resolveTestFlightEnvironment()
                await checkSubscriptionStatus()
                await loadProducts()
            }
        #endif
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Load Products

    public func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let storeProducts = try await Product.products(
                for: PremiumProduct.allIdentifiers
            )

            logger
                .info(
                    "Loaded \(storeProducts.count) products: \(storeProducts.map(\.id).joined(separator: ", "), privacy: .public)"
                )

            // Sort: monthly first, then annual, then lifetime
            products = storeProducts.sorted { lhs, rhs in
                let order: (Product) -> Int = { p in
                    switch p.id {
                    case SubscriptionProduct.monthly.rawValue: return 0
                    case SubscriptionProduct.annual.rawValue: return 1
                    case LifetimeProduct.lifetime.rawValue: return 2
                    default: return 3
                    }
                }
                return order(lhs) < order(rhs)
            }

        } catch {
            logger.error("Failed to load products: \(error, privacy: .public)")
        }
    }

    // MARK: - Purchase

    @discardableResult
    public func purchase(_ product: Product) async -> Bool {
        if BuildEnvironment.isDirectDistribution {
            logger.warning("purchase() called on Direct build – ignoring (entitlement is web-based)")
            return false
        }
        isPurchasing = true
        purchaseError = nil
        purchaseFailedDeviceVerification = false
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase(options: [.appAccountToken(Self.appAccountToken())])

            switch result {
            case let .success(verification):
                let transaction = try checkVerified(verification)
                updateUsageSubject(from: transaction)
                await transaction.finish()
                if PremiumProduct.allIdentifiers.contains(transaction.productID) {
                    activePremiumProductID = transaction.productID
                    updatePremiumStatus(true)
                }
                await checkSubscriptionStatus()
                logger.info("Purchase successful: \(product.id, privacy: .public)")
                return true

            case .userCancelled:
                logger.debug("Purchase cancelled by user")

            case .pending:
                logger.debug("Purchase pending")

            @unknown default:
                logger.debug("Unknown purchase result")
            }
            return false
        } catch {
            purchaseError = error.localizedDescription
            purchaseFailedDeviceVerification = Self.isInvalidDeviceVerification(error)
            logger.error("Purchase failed: \(error, privacy: .public)")
            return false
        }
    }

    // MARK: - Restore Purchases

    public func restorePurchases() async {
        if BuildEnvironment.isDirectDistribution {
            logger.warning("restorePurchases() called on Direct build – delegating to web entitlement refresh")
            await Entitlement.shared.refresh()
            return
        }
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }

        do {
            try await AppStore.sync()
            await checkSubscriptionStatus()
            logger.info("Restore completed")
        } catch {
            purchaseError = error.localizedDescription
            logger.error("Restore failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Check Subscription Status

    public func refreshSubscriptionStatus() async {
        #if !DEBUG
            await resolveTestFlightEnvironment()
        #endif
        await checkSubscriptionStatus()
    }

    public func checkSubscriptionStatus() async {
        #if DEBUG
            let hasDebugPremium = !isTestFlightOverride
            premiumSourceDisplayName = hasDebugPremium ? String(localized: "Debug") : nil
            updatePremiumStatus(hasDebugPremium)
        #else
            if Self.isTestFlight || Self.isAppExtension {
                isTestFlightOverride = AppPreferences.sharedDefaults.bool(forKey: Self.testFlightOverrideKey)
            } else {
                isTestFlightOverride = false
                AppPreferences.sharedDefaults.removeObject(forKey: Self.testFlightOverrideKey)
            }

            // TestFlight override takes precedence
            if isTestFlightOverride {
                premiumSourceDisplayName = String(localized: "TestFlight")
                updatePremiumStatus(true)
                return
            }

            premiumSourceDisplayName = nil
            var hasActiveSubscription = false
            var activeProductID: String?

            for await result in Transaction.currentEntitlements {
                guard let transaction = try? checkVerified(result) else { continue }

                if PremiumProduct.allIdentifiers.contains(transaction.productID) {
                    updateUsageSubject(from: transaction)
                    if transaction.revocationDate == nil {
                        hasActiveSubscription = true
                        let newPriority = PremiumProduct.tierPriority(for: transaction.productID)
                        let currentPriority = activeProductID.map { PremiumProduct.tierPriority(for: $0) } ?? -1
                        if newPriority > currentPriority {
                            activeProductID = transaction.productID
                        }
                    }
                }
            }

            activePremiumProductID = activeProductID
            updatePremiumStatus(hasActiveSubscription)
        #endif
    }

    // MARK: - TestFlight Environment Probe

    /// Authoritative TestFlight detection via `AppTransaction` (covers macOS, where the
    /// receipt filename heuristic can't distinguish TestFlight from Mac App Store).
    /// Also restores a previously saved TestFlight override that the synchronous
    /// `isTestFlight` check may have missed before this probe completed.
    private func resolveTestFlightEnvironment() async {
        do {
            let verification = try await AppTransaction.shared
            let transaction = try checkVerified(verification)
            let isSandbox = transaction.environment == .sandbox
            Self.isTestFlightEnvironmentCached = isSandbox
            logger.info("AppTransaction environment: \(String(describing: transaction.environment), privacy: .public)")

            if isSandbox {
                let storedOverride = AppPreferences.sharedDefaults.bool(forKey: Self.testFlightOverrideKey)
                if storedOverride, !isTestFlightOverride {
                    isTestFlightOverride = true
                    premiumSourceDisplayName = String(localized: "TestFlight")
                    updatePremiumStatus(true)
                }
            }
        } catch {
            logger.error("AppTransaction probe failed: \(error, privacy: .public)")
        }
    }

    // MARK: - TestFlight Premium Toggle

    @discardableResult
    public func toggleTestFlightPremium() -> Bool {
        // The Direct distribution channel must never grant premium via the
        // TestFlight backdoor — premium there comes exclusively from the
        // web entitlement (Supabase + Dodo).
        if BuildEnvironment.isDirectDistribution {
            logger.warning("TestFlight backdoor invoked in Direct build — ignoring")
            return isPremium
        }
        #if DEBUG
            let newValue = !isTestFlightOverride
            isTestFlightOverride = newValue
            AppPreferences.sharedDefaults.set(newValue, forKey: Self.testFlightOverrideKey)
            premiumSourceDisplayName = newValue ? nil : String(localized: "Debug")
            updatePremiumStatus(!newValue)
            DebugNetworkProtocol.refreshLoggingEnabled()
            return !newValue
        #else
            guard Self.isTestFlight else { return false }
            let newValue = !isTestFlightOverride
            isTestFlightOverride = newValue
            AppPreferences.sharedDefaults.set(newValue, forKey: Self.testFlightOverrideKey)
            premiumSourceDisplayName = newValue ? String(localized: "TestFlight") : nil
            updatePremiumStatus(newValue)
            DebugNetworkProtocol.refreshLoggingEnabled()
            if !newValue {
                Task { await checkSubscriptionStatus() }
            }
            return newValue
        #endif
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if let transaction = try? await self.checkVerified(result) {
                    await transaction.finish()
                    await self.checkSubscriptionStatus()
                }
            }
        }
    }

    // MARK: - Helpers

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case let .unverified(_, error):
            throw error
        case let .verified(safe):
            return safe
        }
    }

    private static func isInvalidDeviceVerification(_ error: Error) -> Bool {
        String(reflecting: error).contains("invalidDeviceVerification")
    }

    private func updatePremiumStatus(_ newValue: Bool) {
        guard isPremium != newValue else { return }
        isPremium = newValue
        if !newValue {
            activePremiumProductID = nil
            premiumSourceDisplayName = nil
        }
        AppPreferences.sharedDefaults.set(newValue, forKey: Self.premiumKey)
        AppPreferences.sharedDefaults.synchronize()
        logger.info("Premium status updated: \(newValue, privacy: .public)")
    }

    private static func appAccountToken() -> UUID {
        if let raw = AppPreferences.sharedDefaults.string(forKey: appAccountTokenKey),
           let existing = UUID(uuidString: raw)
        {
            return existing
        }

        let token = UUID()
        AppPreferences.sharedDefaults.set(token.uuidString, forKey: appAccountTokenKey)
        return token
    }

    private func updateUsageSubject(from transaction: Transaction) {
        let subjectID: String
        if let appAccountToken = transaction.appAccountToken {
            subjectID = "appstore:\(appAccountToken.uuidString.lowercased())"
        } else {
            subjectID = "appstore-original:\(transaction.originalID)"
        }

        guard usageAppStoreSubjectID != subjectID else { return }
        usageAppStoreSubjectID = subjectID
        AppPreferences.sharedDefaults.set(subjectID, forKey: Self.usageAppStoreSubjectIDKey)
    }

    // MARK: - Convenience

    /// Monthly product, if available.
    public var monthlyProduct: Product? {
        products.first { $0.id == SubscriptionProduct.monthly.rawValue }
    }

    /// Annual product, if available.
    public var annualProduct: Product? {
        products.first { $0.id == SubscriptionProduct.annual.rawValue }
    }

    /// Lifetime product, if available.
    public var lifetimeProduct: Product? {
        products.first { $0.id == LifetimeProduct.lifetime.rawValue }
    }

    /// Subscription-only products (excludes lifetime).
    public var subscriptionProducts: [Product] {
        products.filter { SubscriptionProduct.allIdentifiers.contains($0.id) }
    }
}
