import Foundation
import SwiftUI

/// App input delivery is separate from popup and extension-owned translation models.
@MainActor
public final class HomeInputRouter {
    public enum Request {
        case serviceText(String)
        case deepLink(text: String, actionName: String?, configName: String?)
        case handoff(HomeViewModel.StateSnapshot)
    }

    public static let shared = HomeInputRouter()

    private var receivers: [UUID: (routeID: UUID, receive: (Request) -> Void)] = [:]
    private var receiverOrder: [UUID] = []
    private var routes: [UUID: (routeID: UUID, activate: () -> Void)] = [:]
    private var routeOrder: [UUID] = []
    private var pending: (request: Request, routeID: UUID?)?

    public init() {}

    public func submit(_ request: Request, routeID: UUID? = nil) {
        pending = (request, routeID)
        deliverPendingRequest()
    }

    public func registerRoute(id: UUID, routeID: UUID, activate: @escaping () -> Void) {
        routes[id] = (routeID, activate)
        routeOrder.removeAll { $0 == id }
        routeOrder.append(id)
        deliverPendingRequest()
    }

    public func unregisterRoute(id: UUID) {
        let removedRoute = routes.removeValue(forKey: id)
        routeOrder.removeAll { $0 == id }
        guard let removedRoute else { return }
        let hasRemainingRoute = routes.values.contains { $0.routeID == removedRoute.routeID }
        if pending?.routeID == removedRoute.routeID, !hasRemainingRoute {
            pending?.routeID = nil
            deliverPendingRequest()
        }
    }

    public func registerReceiver(id: UUID, routeID: UUID, receive: @escaping (Request) -> Void) {
        receivers[id] = (routeID, receive)
        receiverOrder.removeAll { $0 == id }
        receiverOrder.append(id)
        deliverPendingRequest()
    }

    public func unregisterReceiver(id: UUID) {
        receivers[id] = nil
        receiverOrder.removeAll { $0 == id }
    }

    private func deliverPendingRequest() {
        guard let request = pending else { return }
        guard let route = routeOrder.reversed().compactMap({ routes[$0] }).first(where: {
            request.routeID == nil || $0.routeID == request.routeID
        }) else { return }

        // Keep ownership stable while navigation mounts Home; another window must not steal it.
        pending?.routeID = route.routeID
        route.activate()
        guard let receiver = receiverOrder.reversed().compactMap({ receivers[$0] })
            .first(where: { $0.routeID == route.routeID }) else { return }
        pending = nil
        receiver.receive(request.request)
    }
}

public extension EnvironmentValues {
    @Entry var homeInputRouteID: UUID?
}

private struct HomeInputDestination: ViewModifier {
    @Environment(\.homeInputRouteID) private var routeID
    @Environment(\.scenePhase) private var scenePhase
    @State private var registrationID = UUID()
    let activate: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: register)
            .onDisappear {
                HomeInputRouter.shared.unregisterRoute(id: registrationID)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    register()
                }
            }
    }

    private func register() {
        guard let routeID else { return }
        HomeInputRouter.shared.registerRoute(id: registrationID, routeID: routeID, activate: activate)
    }
}

public extension View {
    func homeInputDestination(activate: @escaping () -> Void) -> some View {
        modifier(HomeInputDestination(activate: activate))
    }
}
