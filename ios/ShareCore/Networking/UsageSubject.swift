//
//  UsageSubject.swift
//  ShareCore
//

import Foundation

struct UsageSubject {
    let type: String
    let id: String
    let label: String
}

enum UsageSubjectProvider {
    static func current() async -> UsageSubject? {
        await MainActor.run {
            if let tokens = OAuthTokenStore.load(),
               !tokens.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let email = tokens.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return UsageSubject(type: "email", id: email, label: email)
            }

            if let email = WebEntitlementProvider.shared.email?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                !email.isEmpty
            {
                return UsageSubject(type: "email", id: email, label: email)
            }

            guard !BuildEnvironment.isDirectDistribution,
                  StoreManager.shared.isPremium,
                  let appStoreSubjectID = StoreManager.shared.usageAppStoreSubjectID
            else {
                return nil
            }

            return UsageSubject(
                type: "app_store",
                id: appStoreSubjectID,
                label: appStoreLabel(for: appStoreSubjectID)
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
