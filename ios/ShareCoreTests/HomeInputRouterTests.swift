import Foundation
@testable import ShareCore
import Testing

@MainActor
struct HomeInputRouterTests {
    @Test func coldRequestWaitsForHomeAndIsConsumedOnce() {
        let router = HomeInputRouter()
        let routeID = UUID()
        let receiverID = UUID()
        var received: [String] = []
        router.submit(.serviceText("cold input"), routeID: routeID)
        router.registerReceiver(id: receiverID, routeID: routeID) { request in
            if case let .serviceText(text) = request {
                received.append(text)
            }
        }
        #expect(received.isEmpty)
        router.registerRoute(id: UUID(), routeID: routeID) {}
        #expect(received == ["cold input"])
        router.unregisterReceiver(id: receiverID)
        router.registerReceiver(id: UUID(), routeID: routeID) { _ in
            Issue.record("A consumed request must not replay when Home remounts")
        }
    }

    @Test func newestRequestReplacesOlderColdInputWithoutLosingDeepLinkOptions() {
        let router = HomeInputRouter()
        let routeID = UUID()
        var received: [String] = []
        router.submit(.serviceText("old"), routeID: routeID)
        router.submit(.deepLink(text: "new", actionName: "Explain", configName: "Work"), routeID: routeID)
        router.registerRoute(id: UUID(), routeID: routeID) {}
        router.registerReceiver(id: UUID(), routeID: routeID) { request in
            if case let .deepLink(text, actionName, configName) = request {
                received = [text, actionName ?? "", configName ?? ""]
            } else {
                Issue.record("Only the latest pending request should be delivered")
            }
        }
        #expect(received == ["new", "Explain", "Work"])
    }

    @Test func onlyOneHomeConsumesUntargetedInput() {
        let router = HomeInputRouter()
        var deliveries = 0
        let firstRoute = UUID()
        let secondRoute = UUID()
        router.registerRoute(id: UUID(), routeID: firstRoute) {}
        router.registerRoute(id: UUID(), routeID: secondRoute) {}
        router.registerReceiver(id: UUID(), routeID: firstRoute) { _ in deliveries += 1 }
        router.registerReceiver(id: UUID(), routeID: secondRoute) { _ in deliveries += 1 }
        router.submit(.serviceText("once"))
        #expect(deliveries == 1)
    }

    @Test func navigationActivatesBeforeMountedHomeReceivesInput() {
        let router = HomeInputRouter()
        let routeID = UUID()
        var events: [String] = []
        router.registerRoute(id: UUID(), routeID: routeID) { events.append("home") }
        router.registerReceiver(id: UUID(), routeID: routeID) { _ in events.append("input") }
        router.submit(.serviceText("translate"))
        #expect(events == ["home", "input"])
    }

    @Test func targetedLinkWaitsForItsOwnHomeInsteadOfAnotherWindow() {
        let router = HomeInputRouter()
        let target = UUID()
        let other = UUID()
        router.registerRoute(id: UUID(), routeID: other) {
            Issue.record("The other window must not navigate")
        }
        router.registerReceiver(id: UUID(), routeID: other) { _ in
            Issue.record("The other Home must not receive the link")
        }
        router.submit(.deepLink(text: "targeted", actionName: nil, configName: nil), routeID: target)
        var received = false
        router.registerRoute(id: UUID(), routeID: target) {}
        router.registerReceiver(id: UUID(), routeID: target) { _ in received = true }
        #expect(received)
    }

    @Test func handoffSurvivesColdWindowAndPreservesSnapshot() throws {
        let router = HomeInputRouter()
        let routeID = UUID()
        let snapshot = HomeViewModel.StateSnapshot(
            inputText: "edited input",
            currentRequestInputText: "submitted input",
            selectedActionID: "explain",
            modelRuns: [
                .init(
                    model: ModelConfig(id: "fixture", displayName: "Fixture"),
                    status: .success(.init(text: "translated", copyText: "copy", duration: 0.5))
                ),
            ]
        )
        router.submit(.handoff(snapshot))
        var received: HomeViewModel.StateSnapshot?
        router.registerRoute(id: UUID(), routeID: routeID) {}
        router.registerReceiver(id: UUID(), routeID: routeID) { request in
            if case let .handoff(value) = request {
                received = value
            }
        }
        #expect(received?.inputText == snapshot.inputText)
        #expect(received?.currentRequestInputText == snapshot.currentRequestInputText)
        #expect(received?.selectedActionID == snapshot.selectedActionID)
        let run = try #require(received?.modelRuns.first)
        #expect(run.id == "fixture")
        guard case let .success(result) = run.status else {
            Issue.record("Handoff must retain the existing result without starting a new request")
            return
        }
        #expect(result.text == "translated")
        #expect(result.copyText == "copy")
        #expect(result.duration == 0.5)
    }

    @Test func replacingHomeReceiverDoesNotDuplicateOrUnregisterNewReceiver() {
        let router = HomeInputRouter()
        let routeID = UUID()
        let oldReceiver = UUID()
        let newReceiver = UUID()
        var received = 0
        router.registerRoute(id: UUID(), routeID: routeID) {}
        router.registerReceiver(id: oldReceiver, routeID: routeID) { _ in
            Issue.record("The replaced Home must not consume input")
        }
        router.registerReceiver(id: newReceiver, routeID: routeID) { _ in received += 1 }
        router.submit(.serviceText("first"))
        router.unregisterReceiver(id: oldReceiver)
        router.submit(.serviceText("second"))
        #expect(received == 2)
    }

    @Test func closingWindowBeforeHomeMountsKeepsInputForNextWindow() {
        let router = HomeInputRouter()
        let registration = UUID()
        router.registerRoute(id: registration, routeID: UUID()) {}
        router.submit(.serviceText("waiting"))
        router.unregisterRoute(id: registration)
        let nextWindow = UUID()
        var received = false
        router.registerRoute(id: UUID(), routeID: nextWindow) {}
        router.registerReceiver(id: UUID(), routeID: nextWindow) { _ in received = true }
        #expect(received)
    }
}
