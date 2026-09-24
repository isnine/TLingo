//
//  OAuthPKCE.swift
//  ShareCore
//
//  RFC 7636 helpers for the activation flow. See docs/oauth-activation-spec.md.
//

import CryptoKit
import Foundation

public enum OAuthPKCE {
    /// 32 random bytes → 43-character base64url. Within RFC 7636's 43–128 bound.
    public static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    /// `base64url(SHA256(verifier))` — matches `code_challenge_method = S256`.
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64url(Data(digest))
    }

    /// 16 random bytes for the OAuth `state` parameter.
    public static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
