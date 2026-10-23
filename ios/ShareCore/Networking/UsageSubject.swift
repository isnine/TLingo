//
//  UsageSubject.swift
//  ShareCore
//

import Foundation
import Security

struct UsageSubject {
    let type: String
    let id: String
    let label: String
}

enum UsageSubjectProvider {
    static func current() async -> UsageSubject? {
        await MainActor.run {
            if StoreManager.shared.isPremium,
               let appStoreSubjectID = StoreManager.shared.usageAppStoreSubjectID
            {
                return UsageSubject(
                    type: "app_store",
                    id: appStoreSubjectID,
                    label: appStoreLabel(for: appStoreSubjectID)
                )
            }

            guard let deviceID = DeviceIdentifierStore.current() else { return nil }
            return UsageSubject(
                type: "device",
                id: "device:\(deviceID)",
                label: "Device \(deviceID.prefix(8))"
            )
        }
    }

    private static func appStoreLabel(for subjectID: String) -> String {
        let rawID = subjectID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? subjectID
        let compactID = rawID.replacingOccurrences(of: "-", with: "")
        let suffix = compactID.isEmpty ? rawID : String(compactID.prefix(8))
        return "App Store \(suffix)"
    }
}

/// Random per-device install identifier kept in the Keychain so it survives
/// reinstalls; it is not derived from hardware or advertising identifiers.
@MainActor
enum DeviceIdentifierStore {
    private static let service = "com.zanderwang.AITranslator.DeviceIdentifier"
    private static let account = "default"
    private static var cached: String?

    static func current() -> String? {
        if let cached { return cached }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
            // The legacy login keychain binds item ACLs to the creating app's
            // signature, so App Store and Debug builds sharing this item would
            // trigger a password prompt.
            query[kSecUseDataProtectionKeychain as String] = true
        #endif

        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let stored = String(data: data, encoding: .utf8),
           !stored.isEmpty
        {
            cached = stored
            return stored
        }

        let generated = UUID().uuidString.lowercased()
        var add = query
        add[kSecValueData as String] = Data(generated.utf8)
        // ThisDeviceOnly keeps the identifier out of iCloud Keychain sync.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        cached = generated
        return generated
    }
}
