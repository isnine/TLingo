//
//  DeveloperMode.swift
//  ShareCore
//
//  Runtime gate that exposes debug-only features (currently the network
//  request inspector) to a hard-coded developer email on Direct builds,
//  and preserves the existing TestFlight override toggle on TestFlight
//  builds. Local Debug builds also expose the inspector. App Store builds never see these features.
//

import Foundation

/// Runtime developer-mode flag. Source of truth for gating features that
/// were previously `#if DEBUG`-only (network request inspector, etc.).
///
/// Enabled for local Debug builds, or when:
/// - The Direct build is signed in via OAuth as the developer's email, OR
/// - The TestFlight build has the existing TestFlight override active.
///
/// App Store production builds (no TestFlight, no Direct) always return
/// `false`, so the App Store binary never exposes inspector UI even though
/// the code paths are compiled in.
public enum DeveloperMode {
    /// Hard-coded developer email. Lowercased comparison.
    public static let developerEmail = "xiaozwan@outlook.com"

    /// Synchronous read for SwiftUI / call sites. Cheap (UserDefaults +
    /// keychain look-up via OAuthTokenStore.load) — fine to call per-render
    /// for typical UI traffic. Hot paths (per-request logging) should
    /// cache the result if they care.
    @MainActor
    public static var isEnabled: Bool {
        if isEnabledNonisolated {
            return true
        }
        if StoreManager.isTestFlight, StoreManager.shared.isTestFlightOverride {
            return true
        }
        return false
    }

    /// Direct-only check: signed-in OAuth email matches the developer.
    /// Safe to read from any actor (keychain access is sync and thread-safe).
    public static var isDeveloperSignedInDirect: Bool {
        guard !SnapshotLaunchArguments.isSnapshotMode() else { return false }
        guard BuildEnvironment.isDirectDistribution else { return false }
        guard let tokens = OAuthTokenStore.load() else { return false }
        return tokens.email.lowercased() == developerEmail
    }

    /// Non-isolated probe usable from any actor — including the URLProtocol
    /// hot path (`DebugNetworkProtocol.canInit`) which runs off the main
    /// actor. Mirrors `isEnabled` without touching `StoreManager.shared`
    /// (which is `@MainActor`) by reading the persisted TestFlight override
    /// flag directly from UserDefaults.
    public static var isEnabledNonisolated: Bool {
        #if DEBUG
            return true
        #else
            if isDeveloperSignedInDirect {
                return true
            }
            // App Store / TestFlight: the override is persisted in the App Group
            // defaults and only meaningful in TestFlight builds. We can't call
            // `StoreManager.isTestFlight` here cheaply (it's main-actor isolated
            // for caching), so fall back to the bundle path probe — same logic
            // `StoreManager.isTestFlight` uses on first read.
            guard isLikelyTestFlight else { return false }
            return AppPreferences.sharedDefaults.bool(forKey: testFlightOverrideKey)
        #endif
    }

    private static let testFlightOverrideKey = "testflight_premium_override"

    private static var isLikelyTestFlight: Bool {
        var appURL = Bundle.main.bundleURL
        if appURL.pathExtension == "appex" {
            while appURL.pathExtension != "app", appURL.path != "/" {
                appURL.deleteLastPathComponent()
            }
        }
        guard let receiptURL = Bundle(url: appURL)?.appStoreReceiptURL else { return false }
        if receiptURL.lastPathComponent == "sandboxReceipt" {
            return true
        }
        return Bundle.main.bundlePath.contains("/TestFlight/")
    }
}
