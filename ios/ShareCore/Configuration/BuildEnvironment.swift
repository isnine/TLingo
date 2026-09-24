//
//  BuildEnvironment.swift
//  ShareCore
//
//  Created by AITranslator on 2025/01/31.
//

import Foundation

/// Build/runtime environment flags.
///
/// Hard-coded keys and secrets live in `AppSecrets`. This enum only exposes
/// derived/runtime state (distribution channel, configuration validity, debug
/// description).
public enum BuildEnvironment {
    /// Whether cloud service credentials are configured
    public static var isCloudConfigured: Bool {
        !AppSecrets.cloudSecret.isEmpty
    }

    /// Whether the Direct build's web auth is wired up.
    public static var isSupabaseConfigured: Bool {
        !AppSecrets.supabaseAnonKey.isEmpty
    }

    /// Whether this binary is the Direct (Developer ID, Sparkle) distribution.
    ///
    /// ShareCore is a single framework consumed by both the App Store app
    /// target and the Direct app target, so a `#if DIRECT_DISTRIBUTION` check
    /// in here can never work — the framework is compiled exactly once.
    /// Instead the Direct app target sets this flag at launch via
    /// `BuildEnvironment.markAsDirectDistribution()` (guarded by its own
    /// `#if DIRECT_DISTRIBUTION`). App Store builds simply never call it,
    /// leaving the flag `false`.
    ///
    /// IMPORTANT: must be set before any code reads it (StoreManager,
    /// AppPreferences, Entitlement). Call as the very first line of
    /// `@main`'s `init()`.
    public private(set) static var isDirectDistribution: Bool = false

    /// Called once by the Direct app target at startup. Idempotent.
    public static func markAsDirectDistribution() {
        if isDirectDistribution { return }
        isDirectDistribution = true
    }

    /// Validates that required configuration is present.
    /// - Returns: Array of missing configuration descriptions
    public static func validateConfiguration() -> [String] {
        AppSecrets.cloudSecret.isEmpty ? ["Cloud Secret"] : []
    }

    /// Debug description of current configuration (secrets redacted)
    public static var debugDescription: String {
        let secret = AppSecrets.cloudSecret
        return """
        BuildEnvironment:
          - Cloud Endpoint: \(AppSecrets.cloudEndpoint.absoluteString)
          - Cloud Secret: \(secret.isEmpty ? "(not set)" : "(set, \(secret.count) chars)")
          - Is Configured: \(isCloudConfigured)
          - Supabase: \(isSupabaseConfigured ? "configured" : "not configured")
          - Direct Distribution: \(isDirectDistribution)
        """
    }
}
