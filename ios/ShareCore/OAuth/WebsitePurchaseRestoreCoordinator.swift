//
//  WebsitePurchaseRestoreCoordinator.swift
//  ShareCore
//

import Combine
import Foundation
import os

private let websiteRestoreLogger = os.Logger(
    subsystem: "com.zanderwang.AITranslator",
    category: "WebsitePurchaseRestore"
)

@MainActor
public final class WebsitePurchaseRestoreCoordinator: ObservableObject {
    public static let shared = WebsitePurchaseRestoreCoordinator()

    @Published public private(set) var inFlight: Bool = false
    @Published public private(set) var lastError: String?

    private struct PendingFlow {
        let email: String
        let verifier: String
        let challenge: String
        let state: String
    }

    private let urlSession: URLSession
    private let pkce: WebsiteRestorePKCE
    private let tokenInstaller: (OAuthTokens) -> Void
    private var pending: PendingFlow?

    public convenience init(urlSession: URLSession = .shared) {
        self.init(
            urlSession: urlSession,
            pkce: .live,
            tokenInstaller: { OAuthCoordinator.shared.installRestoredTokens($0) }
        )
    }

    init(
        urlSession: URLSession,
        pkce: WebsiteRestorePKCE,
        tokenInstaller: @escaping (OAuthTokens) -> Void
    ) {
        self.urlSession = urlSession
        self.pkce = pkce
        self.tokenInstaller = tokenInstaller
    }

    public func sendCode(email rawEmail: String) async -> Bool {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.count >= 4 else {
            lastError = String(localized: "Enter a valid email address.")
            return false
        }

        let material = pkce.make()
        let flow = PendingFlow(
            email: email,
            verifier: material.verifier,
            challenge: material.challenge,
            state: material.state
        )

        inFlight = true
        defer { inFlight = false }
        do {
            try await postJSON(path: "auth/email/start", body: ["email": email], expectBody: false)
            pending = flow
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func verifyCode(_ rawCode: String) async -> Bool {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pending else {
            lastError = String(localized: "Request a new code first.")
            return false
        }
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            lastError = String(localized: "Enter the 6-digit code from your email.")
            return false
        }

        inFlight = true
        defer { inFlight = false }

        do {
            let config = OAuthClientConfiguration.currentWebsiteRestore
            let verify = try await postJSON(
                path: "auth/email/verify",
                body: [
                    "email": pending.email,
                    "otp": code,
                    "client_id": config.clientID,
                    "redirect_uri": config.redirectURI,
                    "code_challenge": pending.challenge,
                    "code_challenge_method": "S256",
                    "state": pending.state,
                ],
                responseType: EmailVerifyResponse.self
            )
            let authCode = try parseAuthorizationCode(
                redirectURL: verify.redirectURL,
                expectedState: pending.state
            )
            let tokens = try await exchange(code: authCode, verifier: pending.verifier, config: config)
            self.pending = nil
            guard tokens.isPremium else {
                lastError = String(localized: "This email has no active website purchase.")
                websiteRestoreLogger.info(
                    "restore verified user=\(tokens.userID, privacy: .public) premium=false"
                )
                return false
            }
            tokenInstaller(tokens)
            lastError = nil
            websiteRestoreLogger.info(
                "restore verified user=\(tokens.userID, privacy: .public) premium=true"
            )
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func exchange(
        code: String,
        verifier: String,
        config: OAuthClientConfiguration
    ) async throws -> OAuthTokens {
        let response = try await postJSON(
            path: "oauth/token",
            body: [
                "grant_type": "authorization_code",
                "code": code,
                "code_verifier": verifier,
                "client_id": config.clientID,
                "redirect_uri": config.redirectURI,
            ],
            responseType: TokenResponse.self
        )
        let claims = jwtClaims(from: response.accessToken)
        return OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            accessExpiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            userID: claims["sub"] as? String ?? "",
            email: claims["email"] as? String ?? "",
            plan: response.entitlement?.plan,
            isPremium: response.entitlement?.isPremium ?? false,
            entitlementExpiresAt: parseOAuthEntitlementDate(response.entitlement?.currentPeriodEnd)
        )
    }

    private func parseAuthorizationCode(redirectURL: String, expectedState: String) throws -> String {
        guard let url = URL(string: redirectURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw WebsiteRestoreError.invalidResponse
        }
        let code = components.queryItems?.first { $0.name == "code" }?.value
        let state = components.queryItems?.first { $0.name == "state" }?.value
        guard state == expectedState, let code, !code.isEmpty else {
            throw WebsiteRestoreError.invalidResponse
        }
        return code
    }

    private func postJSON(path: String, body: [String: String], expectBody: Bool) async throws {
        _ = try await performJSONRequest(path: path, body: body, expectBody: expectBody)
    }

    private func postJSON<T: Decodable>(
        path: String,
        body: [String: String],
        responseType _: T.Type = T.self,
        expectBody: Bool = true
    ) async throws -> T {
        let data = try await performJSONRequest(path: path, body: body, expectBody: expectBody)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func performJSONRequest(path: String, body: [String: String], expectBody: Bool = true) async throws -> Data {
        let url = AppSecrets.cloudEndpoint.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebsiteRestoreError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let parsed = try? JSONDecoder().decode(OAuthErrorBody.self, from: data)
            throw WebsiteRestoreError.server(parsed?.errorDescription ?? parsed?.error ?? "HTTP \(http.statusCode)")
        }
        if !expectBody {
            return Data()
        }
        return data
    }
}

struct WebsiteRestorePKCE {
    let make: () -> (verifier: String, challenge: String, state: String)

    static let live = WebsiteRestorePKCE {
        let verifier = OAuthPKCE.generateVerifier()
        return (
            verifier: verifier,
            challenge: OAuthPKCE.challenge(for: verifier),
            state: OAuthPKCE.randomState()
        )
    }

    static func fixed(verifier: String, challenge: String, state: String) -> WebsiteRestorePKCE {
        WebsiteRestorePKCE {
            (verifier: verifier, challenge: challenge, state: state)
        }
    }
}

private struct EmailVerifyResponse: Decodable {
    let redirectURL: String

    enum CodingKeys: String, CodingKey {
        case redirectURL = "redirect_url"
    }
}

private struct TokenResponse: Decodable {
    let tokenType: String
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String
    let entitlement: Entitlement?

    struct Entitlement: Decodable {
        let isPremium: Bool
        let plan: String?
        let currentPeriodEnd: String?

        enum CodingKeys: String, CodingKey {
            case isPremium
            case plan
            case currentPeriodEnd
        }
    }

    enum CodingKeys: String, CodingKey {
        case tokenType = "token_type"
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case entitlement
    }
}

private struct OAuthErrorBody: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private enum WebsiteRestoreError: LocalizedError {
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "Unexpected response from the activation server.")
        case let .server(message):
            return message
        }
    }
}

private func jwtClaims(from jwt: String) -> [String: Any] {
    let parts = jwt.split(separator: ".")
    guard parts.count == 3 else { return [:] }
    var payload = String(parts[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while payload.count % 4 != 0 {
        payload += "="
    }
    guard let data = Data(base64Encoded: payload),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return json
}
