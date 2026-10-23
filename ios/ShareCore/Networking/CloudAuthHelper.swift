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

    /// Attaches the App Store transaction the Worker verifies for premium models.
    static func applyPremiumProof(to request: inout URLRequest) {
        if let transactionJWS = StoreManager.premiumTransactionJWS {
            request.setValue(transactionJWS, forHTTPHeaderField: "X-AppStore-Transaction")
        }
    }
}
