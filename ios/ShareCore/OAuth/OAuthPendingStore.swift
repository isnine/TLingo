//
//  OAuthPendingStore.swift
//  ShareCore
//
//  Persists the in-flight OAuth PKCE state (verifier + state + target URL)
//  to the keychain so that an activation flow survives the user quitting
//  TLingo mid-flow. Without this, the web → tlingo-direct:// callback
//  arrives at a fresh OAuthCoordinator with no `pending`, and the code
//  cannot be redeemed.
//
//  Cleared on successful exchange or terminal callback error.
//

import Foundation
import Security
import os

private let logger = os.Logger(
    subsystem: "com.zanderwang.AITranslator",
    category: "OAuthPendingStore"
)

public struct OAuthPendingFlow: Codable, Equatable {
    public let verifier: String
    public let state: String
    /// The fully-formed activation URL we opened in the browser. Re-opened
    /// by `retryActivation()` so the verifier on disk and the challenge in
    /// the URL stay in sync.
    public let activationURL: URL
    public let createdAt: Date

    public init(verifier: String, state: String, activationURL: URL, createdAt: Date = Date()) {
        self.verifier = verifier
        self.state = state
        self.activationURL = activationURL
        self.createdAt = createdAt
    }

    public var isStale: Bool {
        // PKCE auth codes expire in 10 min server-side; allow a bit longer
        // here so the user has time to receive the OTP email.
        Date().timeIntervalSince(createdAt) > 30 * 60
    }
}

public enum OAuthPendingStore {
    private static let service = "com.zanderwang.AITranslator.OAuthPending"
    private static let account = "default"

    public static func save(_ flow: OAuthPendingFlow) {
        guard let data = try? JSONEncoder().encode(flow) else {
            logger.error("Failed to encode pending flow")
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("Keychain add failed: \(addStatus, privacy: .public)")
            }
        } else if updateStatus != errSecSuccess {
            logger.error("Keychain update failed: \(updateStatus, privacy: .public)")
        }
    }

    public static func load() -> OAuthPendingFlow? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthPendingFlow.self, from: data)
    }

    public static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
