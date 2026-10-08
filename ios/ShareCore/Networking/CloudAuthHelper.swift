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

    static func applyAuth(to request: inout URLRequest, path: String) {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let signature = generateSignature(timestamp: timestamp, path: path)
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")
    }

    /// Marks a premium request. The Worker verifies the App Store transaction
    /// in `X-AppStore-Transaction`; `X-Premium` remains for web entitlements
    /// until those carry a verifiable token too.
    static func applyPremiumProof(to request: inout URLRequest) {
        request.setValue("true", forHTTPHeaderField: "X-Premium")
        if let transactionJWS = StoreManager.premiumTransactionJWS {
            request.setValue(transactionJWS, forHTTPHeaderField: "X-AppStore-Transaction")
        }
    }
}
