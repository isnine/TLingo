import Combine
import Foundation
@testable import ShareCore
import Testing

@Suite("OAuthCoordinator lifecycle")
@MainActor
struct OAuthCoordinatorTests {
    @Test func signOutRejectsLateRefreshSuccess() async {
        let harness = OAuthCoordinatorHarness()
        let coordinator = harness.makeCoordinator()
        let refresh = Task { await coordinator.refreshIfNeeded(force: true) }
        await harness.waitForRequest(0)

        coordinator.signOut()
        harness.succeed(0, with: .fixture("old-refreshed"))

        #expect(await refresh.value == false)
        #expect(coordinator.tokens == nil)
        #expect(harness.savedTokens == nil)
        #expect(harness.entitlementTokens == nil)
        #expect(!coordinator.inFlight)
    }

    @Test func restoredAccountRejectsLateRefreshSuccess() async {
        let harness = OAuthCoordinatorHarness()
        let coordinator = harness.makeCoordinator()
        let refresh = Task { await coordinator.refreshIfNeeded(force: true) }
        await harness.waitForRequest(0)

        coordinator.installRestoredTokens(.fixture("new-account"))
        harness.succeed(0, with: .fixture("old-refreshed"))

        #expect(await refresh.value == false)
        #expect(coordinator.tokens?.refreshToken == "new-account")
        #expect(harness.savedTokens?.refreshToken == "new-account")
        #expect(harness.entitlementTokens?.refreshToken == "new-account")
    }

    @Test func lateRefreshFailureDoesNotFinishNewRequest() async {
        let harness = OAuthCoordinatorHarness()
        let coordinator = harness.makeCoordinator()
        let oldRefresh = Task { await coordinator.refreshIfNeeded(force: true) }
        await harness.waitForRequest(0)

        coordinator.installRestoredTokens(.fixture("new-account"))
        let newRefresh = Task { await coordinator.refreshIfNeeded(force: true) }
        await harness.waitForRequest(1)
        harness.fail(0)

        #expect(await oldRefresh.value == false)
        #expect(coordinator.inFlight)
        #expect(coordinator.tokens?.refreshToken == "new-account")
        #expect(coordinator.lastError == nil)
        harness.succeed(1, with: .fixture("new-refreshed"))
        #expect(await newRefresh.value)
        #expect(!coordinator.inFlight)
        #expect(harness.savedTokens?.refreshToken == "new-refreshed")
    }

    @Test func activationSupersedesRefreshAndCoalescesDuplicateCallbacks() async {
        let harness = OAuthCoordinatorHarness()
        let coordinator = harness.makeCoordinator()
        let refresh = Task { await coordinator.refreshIfNeeded(force: true) }
        await harness.waitForRequest(0)

        #expect(coordinator.handleCallbackIfMatching(harness.callbackURL))
        #expect(coordinator.handleCallbackIfMatching(harness.callbackURL))
        #expect(coordinator.inFlight)
        await harness.waitForRequest(1)
        #expect(harness.requests.count == 2)
        #expect(harness.requests[1]["grant_type"] == "authorization_code")
        harness.succeed(0, with: .fixture("old-refreshed"))
        #expect(await refresh.value == false)
        #expect(coordinator.inFlight)

        harness.succeed(1, with: .fixture("activated"))
        await coordinator.waitForIdle()
        #expect(harness.savedTokens?.refreshToken == "activated")
        #expect(harness.pending == nil)
        #expect(coordinator.lastError == nil)
    }

    @Test func queuedCallbackCannotRestoreTokensAfterSignOut() async {
        let harness = OAuthCoordinatorHarness()
        let coordinator = harness.makeCoordinator()
        #expect(coordinator.handleCallbackIfMatching(harness.callbackURL))
        let activation = coordinator.activationTask
        coordinator.signOut()
        await activation?.value
        #expect(harness.requests.isEmpty)
        #expect(harness.savedTokens == nil)
        #expect(coordinator.tokens == nil)
    }

    @Test func restoredAccountRejectsLateExchangeSuccess() async {
        let harness = OAuthCoordinatorHarness()
        let coordinator = harness.makeCoordinator()
        #expect(coordinator.handleCallbackIfMatching(harness.callbackURL))
        await harness.waitForRequest(0)
        let activation = coordinator.activationTask

        coordinator.installRestoredTokens(.fixture("new-account"))
        harness.succeed(0, with: .fixture("old-activation"))
        await activation?.value

        #expect(coordinator.tokens?.refreshToken == "new-account")
        #expect(harness.savedTokens?.refreshToken == "new-account")
        #expect(harness.entitlementTokens?.refreshToken == "new-account")
        #expect(coordinator.activationIssue == nil)
        #expect(!coordinator.inFlight)
    }

    @Test func startingActivationPreservesLateRefreshSuccess() async {
        let harness = OAuthCoordinatorHarness()
        let coordinator = harness.makeCoordinator()
        let refresh = Task { await coordinator.refreshIfNeeded(force: true) }
        await harness.waitForRequest(0)

        coordinator.startActivation(target: .manage(email: nil))
        let newPending = harness.pending
        #expect(coordinator.inFlight)
        harness.succeed(0, with: .fixture("rotated-account"))

        #expect(await refresh.value)
        #expect(coordinator.tokens?.refreshToken == "rotated-account")
        #expect(harness.savedTokens?.refreshToken == "rotated-account")
        #expect(harness.entitlementTokens?.refreshToken == "rotated-account")
        #expect(harness.pending == newPending)
        #expect(!coordinator.inFlight)
    }

    @Test func newActivationRejectsLateExchangeSuccess() async {
        let harness = OAuthCoordinatorHarness()
        let coordinator = harness.makeCoordinator()
        #expect(coordinator.handleCallbackIfMatching(harness.callbackURL))
        await harness.waitForRequest(0)
        let oldActivation = coordinator.activationTask

        coordinator.startActivation()
        let newPending = harness.pending
        harness.succeed(0, with: .fixture("old-activation"))
        await oldActivation?.value

        #expect(coordinator.tokens?.refreshToken == "old-account")
        #expect(harness.savedTokens?.refreshToken == "old-account")
        #expect(harness.entitlementTokens?.refreshToken == "old-account")
        #expect(harness.pending == newPending)
        #expect(!coordinator.inFlight)
    }

    @Test func newActivationRejectsLateExchangeFailure() async {
        let harness = OAuthCoordinatorHarness()
        let coordinator = harness.makeCoordinator()
        #expect(coordinator.handleCallbackIfMatching(harness.callbackURL))
        await harness.waitForRequest(0)
        let oldActivation = coordinator.activationTask

        coordinator.startActivation()
        let newPending = harness.pending
        #expect(coordinator.handleCallbackIfMatching(harness.callbackURL))
        await harness.waitForRequest(1)
        harness.fail(0)
        await oldActivation?.value
        #expect(coordinator.inFlight)
        #expect(coordinator.lastError == nil)
        #expect(coordinator.activationIssue == nil)
        #expect(harness.pending == newPending)

        harness.succeed(1, with: .fixture("new-activation"))
        await coordinator.waitForIdle()
        #expect(harness.savedTokens?.refreshToken == "new-activation")
    }
}

@MainActor
private final class OAuthCoordinatorHarness {
    var savedTokens: OAuthTokens? = .fixture("old-account")
    var entitlementTokens: OAuthTokens? = .fixture("old-account")
    var pending: OAuthPendingFlow? = OAuthPendingFlow(
        verifier: "test-verifier",
        state: "test-state",
        activationURL: URL(string: "https://example.com/activate")!
    )
    var requests: [[String: String]] = []
    private var continuations: [CheckedContinuation<OAuthTokens, Error>?] = []
    private var requestWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    var callbackURL: URL {
        URL(string: "tlingo-direct://oauth/callback?code=test-code&state=\(pending!.state)")!
    }

    func makeCoordinator() -> OAuthCoordinator {
        OAuthCoordinator(dependencies: OAuthCoordinatorDependencies(
            loadTokens: { self.savedTokens },
            saveTokens: { self.savedTokens = $0 },
            loadPending: { self.pending },
            savePending: { self.pending = $0 },
            applyEntitlement: { self.entitlementTokens = $0 },
            openURL: { _ in },
            installIdentifier: { "test-install" },
            requestTokens: { body in
                try await withCheckedThrowingContinuation { continuation in
                    let index = self.requests.count
                    self.requests.append(body)
                    self.continuations.append(continuation)
                    self.requestWaiters.removeValue(forKey: index)?.resume()
                }
            }
        ))
    }

    func waitForRequest(_ index: Int) async {
        guard requests.count <= index else { return }
        await withCheckedContinuation { requestWaiters[index] = $0 }
    }

    func succeed(_ index: Int, with tokens: OAuthTokens) {
        let continuation = continuations[index]
        continuations[index] = nil
        continuation?.resume(returning: tokens)
    }

    func fail(_ index: Int) {
        let continuation = continuations[index]
        continuations[index] = nil
        continuation?.resume(throwing: URLError(.notConnectedToInternet))
    }
}

private extension OAuthTokens {
    static func fixture(_ identity: String) -> Self {
        Self(
            accessToken: "test-access",
            refreshToken: identity,
            accessExpiresAt: .distantPast,
            userID: identity,
            email: "test@example.com",
            plan: "monthly",
            isPremium: true
        )
    }
}

private extension OAuthCoordinator {
    func waitForIdle() async {
        for await value in $inFlight.values where !value {
            return
        }
    }
}
