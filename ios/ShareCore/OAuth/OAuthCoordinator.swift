//
//  OAuthCoordinator.swift
//  ShareCore
//
//  Drives the email-OTP + PKCE activation flow for the TLingo Mac (Direct)
//  build. End-to-end: user clicks "Restore purchase" → we open the browser
//  on /activate → user verifies email → browser bounces back via
//  `tlingo-direct://oauth/callback` → we exchange the code for tokens and
//  apply the entitlement.
//
//  See docs/oauth-activation-spec.md for the full design.
//

import Combine
import Foundation
import os

#if canImport(AppKit)
    import AppKit
#endif

private let logger = os.Logger(
    subsystem: "com.zanderwang.AITranslator",
    category: "OAuthCoordinator"
)

public extension Notification.Name {
    /// Posted when an OAuth callback URL arrived but no in-app PKCE flow was
    /// pending (e.g. the user completed `/activate` purely on the website
    /// without ever clicking "Restore" in the app). UI should respond by
    /// presenting the paywall so the user can start a fresh in-app activation.
    ///
    /// Mirrored as a sticky `@Published` flag on `OAuthCoordinator` so cold
    /// launches (no view mounted yet) still pick the prompt up.
    static let oauthCallbackNeedsActivation = Notification.Name("com.tlingo.oauthCallbackNeedsActivation")
}

@MainActor
public final class OAuthCoordinator: ObservableObject {
    public static let shared = OAuthCoordinator()

    @Published public private(set) var tokens: OAuthTokens?
    @Published public private(set) var lastError: String?
    @Published public private(set) var activationIssue: OAuthActivationIssue?
    @Published public private(set) var inFlight: Bool = false
    /// Sticky flag set when a `tlingo-direct://oauth/callback` arrives without
    /// a matching pending PKCE flow. UI observes this to present the paywall
    /// and resets it via `acknowledgeActivationPrompt()` after handling.
    @Published public private(set) var needsActivationPrompt: Bool = false

    /// Timestamp of the most recent successful `/oauth/token` exchange or
    /// refresh. Used by `refreshIfStale(maxAge:)` so callers (foreground
    /// transitions, periodic ticks) can throttle without re-implementing
    /// the policy. `nil` means "never refreshed in this process".
    private var lastSuccessfulRefreshAt: Date?

    /// In-flight PKCE state. Persisted to keychain (`OAuthPendingStore`)
    /// so an activation flow survives the user quitting TLingo mid-flow:
    /// otherwise the tlingo-direct:// callback arrives at a fresh
    /// coordinator with no `pending` and the auth code can't be redeemed.
    private var pending: OAuthPendingFlow?

    private let dependencies: OAuthCoordinatorDependencies
    private var generation = UUID()
    private var activeOperation: UUID?
    private var activeExchangeState: String?
    private(set) var activationTask: Task<Void, Never>?

    private convenience init() {
        self.init(dependencies: .live)
    }

    init(dependencies: OAuthCoordinatorDependencies) {
        self.dependencies = dependencies
        guard !SnapshotLaunchArguments.isSnapshotMode() else { return }
        tokens = dependencies.loadTokens()
        if let restored = dependencies.loadPending(), !restored.isStale {
            pending = restored
        } else {
            dependencies.savePending(nil)
        }
    }

    // MARK: - Public API

    /// Where to land the user when starting the activation flow.
    public enum ActivationTarget {
        /// /activate — direct OTP entry (used by "Restore Purchase").
        case activate
        /// Marketing landing's #pricing section — for "Subscribe on Web".
        /// PKCE params are appended so the eventual checkout success URL
        /// can route the user back to /activate?from=checkout pre-filled.
        /// When `email` is non-nil, the web page forwards it to Stripe
        /// Checkout as `prefilled_email`, skipping the email-entry step.
        /// Swift enum cases can't have parameter defaults — pass `.pricing(email: nil)`
        /// at the call site when no prefill is desired.
        case pricing(email: String?)
        /// /manage — email + OTP → Stripe Billing Portal. No PKCE: this
        /// flow doesn't mint tokens, it just opens the portal.
        case manage(email: String?)
    }

    /// Open the system browser at `/activate` (default), `/#pricing`, or
    /// `/manage`. Called from "Restore purchase" / "Subscribe" / "Manage
    /// Account" menu items. All targets carry PKCE so the manage page can
    /// also offer a one-click "Activate this Mac" hand-off.
    public func startActivation(target: ActivationTarget = .activate) {
        // Opening a browser flow must preserve an in-flight refresh's rotated token.
        if activeExchangeState != nil {
            invalidateOperations()
        }
        let verifier = OAuthPKCE.generateVerifier()
        let challenge = OAuthPKCE.challenge(for: verifier)
        let state = OAuthPKCE.randomState()

        let basePath: String
        let fragment: String?
        var extraQuery: [URLQueryItem] = []
        switch target {
        case .activate:
            basePath = "/activate"
            fragment = nil
        case let .pricing(email):
            basePath = "/"
            fragment = "pricing"
            if let trimmed = email?.trimmingCharacters(in: .whitespaces).lowercased(),
               trimmed.contains("@")
            {
                extraQuery.append(URLQueryItem(name: "email", value: trimmed))
            }
        case let .manage(email):
            basePath = "/manage"
            fragment = nil
            if let trimmed = email?.trimmingCharacters(in: .whitespaces).lowercased(),
               trimmed.contains("@")
            {
                extraQuery.append(URLQueryItem(name: "email", value: trimmed))
            }
        }

        var components = URLComponents(string: "https://tlingo.zanderwang.com\(basePath)")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthClientConfiguration.currentWebsiteRestore.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect_uri", value: OAuthClientConfiguration.currentWebsiteRestore.redirectURI),
        ] + extraQuery
        components.fragment = fragment
        guard let url = components.url else {
            lastError = "Failed to construct activation URL."
            return
        }

        let flow = OAuthPendingFlow(verifier: verifier, state: state, activationURL: url)
        pending = flow
        dependencies.savePending(flow)
        lastError = nil
        logger.info("startActivation – opening \(url.redactedLogDescription, privacy: .public)")

        dependencies.openURL(url)
    }

    /// Re-open the most recent activation URL, reusing the keychain-stored
    /// verifier + state. Used by PaywallView's "Try Again" button after a
    /// callback failure (e.g. user closed the browser tab, network blip,
    /// app was killed before the callback arrived). The web `/manage` page
    /// can short-circuit the OTP step if its session cookie is still valid.
    public func retryActivation() {
        guard let flow = pending, !flow.isStale else {
            // Nothing to retry — fall back to a fresh activation flow so
            // the user can recover without restarting the app.
            dependencies.savePending(nil)
            pending = nil
            startActivation(target: .activate)
            return
        }
        lastError = nil
        // Append a cache-busting nonce so the browser performs a real
        // navigation rather than just focusing an existing /manage tab —
        // otherwise renderManage() never re-runs and the manage-resume
        // call that would skip the OTP step never fires.
        let url = appendQueryItem(flow.activationURL, name: "_retry", value: String(Int(Date().timeIntervalSince1970)))
        logger.info("retryActivation – reopening \(url.redactedLogDescription, privacy: .public)")
        dependencies.openURL(url)
    }

    private func appendQueryItem(_ url: URL, name: String, value: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        return components.url ?? url
    }

    /// Returns true if the URL was an OAuth callback that we consumed.
    /// Call this from `.onOpenURL { ... }` in the SwiftUI app.
    public func handleCallbackIfMatching(_ url: URL) -> Bool {
        guard url.scheme == "tlingo-direct", url.host == "oauth", url.path == "/callback" else {
            return false
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let code = comps?.queryItems?.first(where: { $0.name == "code" })?.value
        let state = comps?.queryItems?.first(where: { $0.name == "state" })?.value
        let errorParam = comps?.queryItems?.first(where: { $0.name == "error" })?.value

        if let errorParam, !errorParam.isEmpty {
            let message = String(localized: "Activation cancelled (\(errorParam)). Tap Try Again to retry.")
            lastError = message
            activationIssue = makeActivationIssue(
                message: message,
                errorCode: errorParam,
                activationURL: pending?.activationURL,
                callbackURL: url
            )
            clearPending()
            logger.warning("Callback returned error: \(errorParam, privacy: .public)")
            return true
        }

        guard let pending else {
            let message = String(localized: "Sign-in link expired. Tap Try Again to start over.")
            lastError = message
            activationIssue = makeActivationIssue(
                message: message,
                errorCode: "missing_pending_flow",
                activationURL: nil,
                callbackURL: url
            )
            logger.warning("Callback received with no pending flow")
            needsActivationPrompt = true
            NotificationCenter.default.post(name: .oauthCallbackNeedsActivation, object: nil)
            return true
        }
        guard let code, !code.isEmpty, let state, state == pending.state else {
            let message = String(localized: "Sign-in link is invalid or expired. Tap Try Again to retry.")
            lastError = message
            activationIssue = makeActivationIssue(
                message: message,
                errorCode: "invalid_callback_state",
                activationURL: pending.activationURL,
                callbackURL: url
            )
            clearPending()
            logger.warning("Callback state mismatch or missing code")
            needsActivationPrompt = true
            NotificationCenter.default.post(name: .oauthCallbackNeedsActivation, object: nil)
            return true
        }

        guard activeExchangeState != pending.state else { return true }
        invalidateOperations()
        let operation = beginOperation()
        activeExchangeState = pending.state
        let generation = generation
        activationTask = Task {
            await self.exchange(
                code: code,
                flow: pending,
                callbackURL: url,
                operation: operation,
                generation: generation
            )
        }
        return true
    }

    /// Refresh the access token. Safe to call on app launch.
    /// - Parameter force: when true, refresh even if the access token isn't
    ///   expired. Used by the "Refresh subscription status" UI button.
    @discardableResult
    public func refreshIfNeeded(force: Bool = false) async -> Bool {
        guard let current = tokens else { return false }
        if !force, !current.isAccessTokenExpired {
            return true
        }
        return await refreshNow(reason: force ? "manual" : "access_expired")
    }

    /// Refresh if the last successful refresh is older than `maxAge`. Used
    /// by foreground / periodic triggers so the mirrored entitlement
    /// (`isPremium`, `plan`, `current_period_end`) doesn't grow stale
    /// between app launches — Stripe webhook updates have no client push
    /// channel, so we poll on a leash.
    ///
    /// No-op when there are no tokens (App Store target, or signed out).
    /// Returns `true` if a refresh was performed and succeeded, `false`
    /// when skipped or failed.
    @discardableResult
    public func refreshIfStale(maxAge: TimeInterval, reason: String = "stale") async -> Bool {
        guard tokens != nil else { return false }
        if let last = lastSuccessfulRefreshAt, Date().timeIntervalSince(last) < maxAge {
            return false
        }
        return await refreshNow(reason: reason)
    }

    public func signOut() {
        logger.info("signOut – clearing tokens")
        invalidateOperations()
        tokens = nil
        lastSuccessfulRefreshAt = nil
        clearPending()
        dependencies.saveTokens(nil)
        dependencies.applyEntitlement(nil)
    }

    public func installRestoredTokens(_ tokens: OAuthTokens) {
        invalidateOperations()
        clearPending()
        applyTokens(tokens)
    }

    private func applyTokens(_ tokens: OAuthTokens) {
        self.tokens = tokens
        lastSuccessfulRefreshAt = Date()
        dependencies.saveTokens(tokens)
        dependencies.applyEntitlement(tokens)
    }

    private func invalidateOperations() {
        activationTask?.cancel()
        activationTask = nil
        generation = UUID()
        activeOperation = nil
        activeExchangeState = nil
        inFlight = false
    }

    private func beginOperation() -> UUID {
        let operation = UUID()
        activeOperation = operation
        inFlight = true
        return operation
    }

    private func isCurrent(operation: UUID, generation: UUID) -> Bool {
        self.generation == generation && activeOperation == operation
    }

    private func finishOperation(_ operation: UUID, generation: UUID) {
        guard isCurrent(operation: operation, generation: generation) else { return }
        activationTask = nil
        activeOperation = nil
        activeExchangeState = nil
        inFlight = false
    }

    /// UI calls this once it has presented the activation paywall in
    /// response to `needsActivationPrompt`, so we don't re-trigger on the
    /// next view re-mount.
    public func acknowledgeActivationPrompt() {
        needsActivationPrompt = false
    }

    public func clearActivationIssue() {
        activationIssue = nil
    }

    private func clearPending() {
        pending = nil
        dependencies.savePending(nil)
    }

    // MARK: - Networking

    private func exchange(
        code: String,
        flow: OAuthPendingFlow,
        callbackURL: URL,
        operation: UUID,
        generation: UUID
    ) async {
        guard isCurrent(operation: operation, generation: generation) else { return }
        defer { finishOperation(operation, generation: generation) }
        do {
            let activationURL = flow.activationURL
            let tokens = try await postToken([
                "grant_type": "authorization_code",
                "code": code,
                "code_verifier": flow.verifier,
                "client_id": OAuthClientConfiguration.currentWebsiteRestore.clientID,
                "redirect_uri": OAuthClientConfiguration.currentWebsiteRestore.redirectURI,
            ], refreshReason: nil, activationURL: activationURL, callbackURL: callbackURL)
            guard isCurrent(operation: operation, generation: generation) else { return }
            applyTokens(tokens)
            clearPending()
            lastError = nil
            activationIssue = nil
            logger.info(
                """
                exchange OK – user=\(tokens.userID, privacy: .public) \
                isPremium=\(tokens.isPremium, privacy: .public) \
                plan=\(tokens.plan ?? "nil", privacy: .public)
                """
            )
            if !tokens.isPremium {
                let message = String(
                    localized: "Activation completed, but this account is not Pro. Contact support if you already paid."
                )
                let diagnostics = tokens.activationDiagnostics?.withError(
                    code: "no_active_entitlement",
                    description: message,
                    callbackURL: callbackURL
                ) ?? fallbackDiagnostics(
                    errorCode: "no_active_entitlement",
                    errorDescription: message,
                    activationURL: activationURL,
                    callbackURL: callbackURL
                )
                activationIssue = OAuthActivationIssue(
                    title: String(localized: "Activation needs attention"),
                    message: message,
                    diagnostics: diagnostics
                )
            }
        } catch {
            guard isCurrent(operation: operation, generation: generation) else { return }
            // Keep `pending` so the user can hit Try Again. The auth code
            // itself is consumed at this point, but the verifier and the
            // /manage URL are still useful — the web session cookie will
            // mint a fresh code without re-prompting for OTP.
            let message = String(localized: "Activation failed: \(error.localizedDescription). Tap Try Again.")
            lastError = message
            activationIssue = OAuthActivationIssue(
                title: String(localized: "Activation failed"),
                message: message,
                diagnostics: fallbackDiagnostics(
                    errorCode: "token_exchange_failed",
                    errorDescription: error.localizedDescription,
                    activationURL: pending?.activationURL,
                    callbackURL: callbackURL
                )
            )
            logger.warning("exchange failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    private func refreshNow(reason: String) async -> Bool {
        guard let current = tokens else { return false }
        // Coalesce concurrent refreshes — startup `.task`, foreground
        // notification, and the 6h ticker can otherwise race and issue
        // duplicate /oauth/token round-trips.
        if inFlight {
            logger.debug("refresh skipped – request already in flight")
            return false
        }
        logRefreshStarting(
            current,
            reason: reason,
            lastSuccessfulRefreshAt: lastSuccessfulRefreshAt,
            installIdentifier: dependencies.installIdentifier()
        )
        let operation = beginOperation()
        let generation = generation
        defer { finishOperation(operation, generation: generation) }
        do {
            var refreshBody = [String: String]()
            refreshBody["grant_type"] = "refresh_token"
            refreshBody["refresh_token"] = current.refreshToken
            refreshBody["client_id"] = OAuthClientConfiguration.currentWebsiteRestore.clientID
            let refreshed = try await postToken(
                refreshBody,
                refreshReason: reason,
                activationURL: current.activationDiagnostics?.activationURL,
                callbackURL: nil
            )
            guard isCurrent(operation: operation, generation: generation) else { return false }
            applyTokens(refreshed)
            logRefreshSucceeded(refreshed)
            return true
        } catch {
            guard isCurrent(operation: operation, generation: generation) else { return false }
            logger.warning("refresh failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func postToken(
        _ body: [String: String],
        refreshReason: String?,
        activationURL: URL?,
        callbackURL: URL?
    ) async throws -> OAuthTokens {
        if let requestTokens = dependencies.requestTokens {
            return try await requestTokens(body)
        }
        let url = AppSecrets.cloudEndpoint.appendingPathComponent("oauth/token")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(dependencies.installIdentifier(), forHTTPHeaderField: "X-TLingo-Install-ID")
        req.addValue(OAuthActivationDiagnostics.currentAppVersion, forHTTPHeaderField: "X-TLingo-App-Version")
        req.addValue(currentPlatformName, forHTTPHeaderField: "X-TLingo-Platform")
        if let refreshReason {
            req.addValue(refreshReason, forHTTPHeaderField: "X-TLingo-Refresh-Reason")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }
        if !(200 ..< 300).contains(http.statusCode) {
            let parsed = try? JSONDecoder().decode(OAuthErrorBody.self, from: data)
            let msg = parsed?.errorDescription ?? parsed?.error ?? "HTTP \(http.statusCode)"
            throw OAuthError.server(code: parsed?.error, message: msg)
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            accessExpiresAt: Date().addingTimeInterval(TimeInterval(decoded.expiresIn)),
            userID: extractClaim("sub", from: decoded.accessToken) ?? "",
            email: extractClaim("email", from: decoded.accessToken) ?? "",
            plan: decoded.entitlement?.plan,
            isPremium: decoded.entitlement?.isPremium ?? false,
            entitlementExpiresAt: parseOAuthEntitlementDate(decoded.entitlement?.currentPeriodEnd),
            activationDiagnostics: decoded.activationDiagnostics(
                accessToken: decoded.accessToken,
                activationURL: activationURL,
                callbackURL: callbackURL
            )
        )
    }

    private func makeActivationIssue(
        message: String,
        errorCode: String,
        activationURL: URL?,
        callbackURL: URL?
    ) -> OAuthActivationIssue {
        OAuthActivationIssue(
            title: String(localized: "Activation failed"),
            message: message,
            diagnostics: fallbackDiagnostics(
                errorCode: errorCode,
                errorDescription: message,
                activationURL: activationURL,
                callbackURL: callbackURL
            )
        )
    }

    private func fallbackDiagnostics(
        errorCode: String,
        errorDescription: String,
        activationURL: URL?,
        callbackURL: URL?
    ) -> OAuthActivationDiagnostics {
        OAuthActivationDiagnostics(
            email: tokens?.email ?? "",
            userID: tokens?.userID ?? "",
            isPremium: tokens?.isPremium ?? false,
            errorCode: errorCode,
            errorDescription: errorDescription,
            activationURL: activationURL,
            callbackURL: callbackURL
        )
    }
}

private func logRefreshStarting(
    _ tokens: OAuthTokens,
    reason: String,
    lastSuccessfulRefreshAt: Date?,
    installIdentifier: String
) {
    logger.info(
        """
        refresh starting – user=\(tokens.userID, privacy: .public) \
        client=\(OAuthClientConfiguration.currentWebsiteRestore.clientID, privacy: .public) \
        install=\(installIdentifier, privacy: .public) \
        reason=\(reason, privacy: .public) \
        lastSuccess=\(lastSuccessfulRefreshAt?.ISO8601Format() ?? "nil", privacy: .public) \
        accessExpiresIn=\(tokens.accessExpiresAt.timeIntervalSinceNow, privacy: .public)s
        """
    )
}

private var currentPlatformName: String {
    #if os(macOS)
        return "macOS"
    #elseif os(iOS)
        return "iOS"
    #else
        return "unknown"
    #endif
}

private func logRefreshSucceeded(_ tokens: OAuthTokens) {
    logger.info(
        """
        refresh OK – user=\(tokens.userID, privacy: .public) \
        isPremium=\(tokens.isPremium, privacy: .public) \
        plan=\(tokens.plan ?? "nil", privacy: .public) \
        accessExpiresIn=\(tokens.accessExpiresAt.timeIntervalSinceNow, privacy: .public)s
        """
    )
}

// MARK: - Wire types

private struct TokenResponse: Decodable {
    let tokenType: String
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String
    let entitlement: Entitlement?

    struct Entitlement: Decodable {
        let isPremium: Bool
        let plan: String?
        let status: String?
        let currentPeriodEnd: String?
        let lifetimeAccess: Bool?
        let stripeCustomerId: String?
        let stripeSubscriptionId: String?
        let stripePaymentIntentId: String?
        let stripeCheckoutSessionId: String?
        let stripePriceId: String?
        let amountTotal: Int?
        let currency: String?
    }

    enum CodingKeys: String, CodingKey {
        case tokenType = "token_type"
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case entitlement
    }
}

private extension TokenResponse {
    func activationDiagnostics(
        accessToken: String,
        activationURL: URL?,
        callbackURL: URL?
    ) -> OAuthActivationDiagnostics {
        OAuthActivationDiagnostics(
            email: extractClaim("email", from: accessToken) ?? "",
            userID: extractClaim("sub", from: accessToken) ?? "",
            isPremium: entitlement?.isPremium ?? false,
            errorCode: nil,
            errorDescription: nil,
            activationURL: activationURL,
            callbackURL: callbackURL
        )
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

public enum OAuthError: LocalizedError {
    case invalidResponse
    case server(code: String?, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return String(localized: "Unexpected response from the activation server.")
        case let .server(_, message): return message
        }
    }

    public var invalidatesStoredWebsiteEntitlement: Bool {
        switch self {
        case .invalidResponse:
            return false
        case let .server(code, message):
            if code == "invalid_grant" {
                return true
            }

            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "refresh token expired" ||
                normalized == "refresh token not recognized" ||
                normalized == "refresh token already used" ||
                normalized == "client mismatch"
        }
    }
}

// MARK: - JWT claim helper (no signature verification — server-issued, used purely for display)

private func extractClaim(_ name: String, from jwt: String) -> String? {
    let parts = jwt.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var payload = String(parts[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while payload.count % 4 != 0 {
        payload += "="
    }
    guard let data = Data(base64Encoded: payload) else { return nil }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json[name] as? String
}

enum OAuthRefreshFailurePolicy {
    static func shouldClearStoredWebsiteEntitlement(
        failedRefreshToken: String,
        inMemoryRefreshToken: String?,
        storedRefreshToken: String?
    ) -> Bool {
        inMemoryRefreshToken == failedRefreshToken && (storedRefreshToken == nil || storedRefreshToken == failedRefreshToken)
    }
}

@MainActor
struct OAuthCoordinatorDependencies {
    var loadTokens: () -> OAuthTokens?
    var saveTokens: (OAuthTokens?) -> Void
    var loadPending: () -> OAuthPendingFlow?
    var savePending: (OAuthPendingFlow?) -> Void
    var applyEntitlement: (OAuthTokens?) -> Void
    var openURL: (URL) -> Void
    var installIdentifier: () -> String = { OAuthInstallIdentifier.current }
    var requestTokens: (([String: String]) async throws -> OAuthTokens)?

    static var live: Self {
        Self(
            loadTokens: { OAuthTokenStore.load() },
            saveTokens: { tokens in
                if let tokens {
                    OAuthTokenStore.save(tokens)
                } else {
                    OAuthTokenStore.clear()
                }
            },
            loadPending: { OAuthPendingStore.load() },
            savePending: { flow in
                if let flow {
                    OAuthPendingStore.save(flow)
                } else {
                    OAuthPendingStore.clear()
                }
            },
            applyEntitlement: { tokens in
                if let tokens {
                    WebEntitlementProvider.shared.applyOAuthEntitlement(
                        isPremium: tokens.isPremium,
                        plan: tokens.plan,
                        expiresAt: tokens.entitlementExpiresAt,
                        email: tokens.email
                    )
                } else {
                    WebEntitlementProvider.shared.clearOAuthEntitlement()
                }
            },
            openURL: { url in
                #if canImport(AppKit)
                    NSWorkspace.shared.open(url)
                #endif
            }
        )
    }
}
