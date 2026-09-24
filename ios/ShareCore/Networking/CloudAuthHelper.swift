//
//  CloudAuthHelper.swift
//  ShareCore
//

import CryptoKit
import Foundation

enum CloudAuthHelper {
    private static let symmetricKey: SymmetricKey = .init(data: Data(hexString: CloudServiceConstants.secret) ?? Data())

    static func generateSignature(timestamp: String, path: String) -> String {
        let message = "\(timestamp):\(path)"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
        return Data(signature).hexEncodedString()
    }

    static func generateOnboardingTrialSignature(timestamp: String) -> String {
        let message = "onboarding-trial:\(timestamp)"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
        return Data(signature).hexEncodedString()
    }

    static func applyAuth(to request: inout URLRequest, path: String) {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let signature = generateSignature(timestamp: timestamp, path: path)
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")
    }

    /// Adds standard HMAC auth headers plus `X-Onboarding-Trial`, a second
    /// signature scoped to "onboarding-trial:{timestamp}". The Worker
    /// validates this token to bypass `hasPremiumAccess` for a whitelisted
    /// model set, so a not-yet-subscribed user can try one of their picked
    /// premium models inside the onboarding flow.
    static func applyOnboardingTrialAuth(to request: inout URLRequest, path: String) {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let pathSignature = generateSignature(timestamp: timestamp, path: path)
        let trialSignature = generateOnboardingTrialSignature(timestamp: timestamp)
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(pathSignature, forHTTPHeaderField: "X-Signature")
        request.setValue(trialSignature, forHTTPHeaderField: "X-Onboarding-Trial")
    }
}
