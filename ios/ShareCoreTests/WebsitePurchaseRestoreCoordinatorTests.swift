//
//  WebsitePurchaseRestoreCoordinatorTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("WebsitePurchaseRestoreCoordinator")
struct WebsitePurchaseRestoreCoordinatorTests {
    @MainActor
    @Test func verifyCodeDoesNotInstallTokensWhenEmailHasNoPremiumEntitlement() async throws {
        let session = URLSession(configuration: MockWebsiteRestoreURLProtocol.configuration)
        MockWebsiteRestoreURLProtocol.responses = try [
            "/auth/email/start": .init(statusCode: 204, body: Data()),
            "/auth/email/verify": .json([
                "redirect_url": "\(OAuthClientConfiguration.currentWebsiteRestore.redirectURI)?code=auth-code&state=restore-state",
            ]),
            "/oauth/token": .json([
                "token_type": "Bearer",
                "access_token": Self.jwt(email: "free@example.com", userID: "user_free"),
                "expires_in": 3600,
                "refresh_token": "refresh-free",
                "entitlement": [
                    "isPremium": false,
                    "plan": "free",
                ],
            ]),
        ]
        var installedTokens: OAuthTokens?
        let coordinator = WebsitePurchaseRestoreCoordinator(
            urlSession: session,
            pkce: .fixed(verifier: "verifier", challenge: "challenge", state: "restore-state"),
            tokenInstaller: { installedTokens = $0 }
        )

        let sent = await coordinator.sendCode(email: "free@example.com")
        let verified = await coordinator.verifyCode("123456")

        #expect(sent)
        #expect(!verified)
        #expect(installedTokens == nil)
    }

    private static func jwt(email: String, userID: String) throws -> String {
        let header = try base64URL(["alg": "none"])
        let payload = try base64URL(["sub": userID, "email": email])
        return "\(header).\(payload).signature"
    }

    private static func base64URL(_ object: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class MockWebsiteRestoreURLProtocol: URLProtocol {
    struct Response {
        let statusCode: Int
        let body: Data

        static func json(_ object: [String: Any], statusCode: Int = 200) throws -> Response {
            try .init(statusCode: statusCode, body: JSONSerialization.data(withJSONObject: object))
        }
    }

    static var responses: [String: Response] = [:]

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockWebsiteRestoreURLProtocol.self]
        return configuration
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = Self.responses[url.path] ?? Self.responses.first(where: { url.path.hasSuffix($0.key) })?.value
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty {
            client?.urlProtocol(self, didLoad: response.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
