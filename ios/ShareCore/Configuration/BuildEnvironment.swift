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
/// derived/runtime state (configuration validity, debug description).
public enum BuildEnvironment {
    /// Whether cloud service credentials are configured
    public static var isCloudConfigured: Bool {
        !AppSecrets.cloudSecret.isEmpty
    }

    /// Debug description of current configuration (secrets redacted)
    public static var debugDescription: String {
        let secret = AppSecrets.cloudSecret
        return """
        BuildEnvironment:
          - Cloud Endpoint: \(AppSecrets.cloudEndpoint.absoluteString)
          - Cloud Secret: \(secret.isEmpty ? "(not set)" : "(set, \(secret.count) chars)")
          - Is Configured: \(isCloudConfigured)
        """
    }
}
