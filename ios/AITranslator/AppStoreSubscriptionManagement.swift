//
//  AppStoreSubscriptionManagement.swift
//  TLingo
//

import Combine
import ShareCore
import StoreKit
import SwiftUI

#if os(iOS)
    import UIKit
    import UserNotifications
#endif

@MainActor
final class AppStoreSubscriptionManagementRouter: ObservableObject {
    static let shared = AppStoreSubscriptionManagementRouter()

    @Published var isPresented = false

    private init() {}

    func present() {
        guard !BuildEnvironment.isDirectDistribution else { return }
        isPresented = true
    }
}

struct AppStoreSubscriptionManagementPresenter: ViewModifier {
    @ObservedObject private var router = AppStoreSubscriptionManagementRouter.shared

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .manageSubscriptionsSheet(isPresented: $router.isPresented)
        #else
            content
        #endif
    }
}

enum TrialReminderNotification {
    static let identifier = "tlingo.trial.reminder"

    private static let destinationKey = "destination"
    private static let manageSubscriptionsDestination = "manageSubscriptions"

    #if os(iOS)
        static func configure(_ content: UNMutableNotificationContent) {
            content.userInfo = [destinationKey: manageSubscriptionsDestination]
        }

        static func opensManageSubscriptions(_ request: UNNotificationRequest) -> Bool {
            request.identifier == identifier
                || request.content.userInfo[destinationKey] as? String == manageSubscriptionsDestination
        }
    #endif
}

#if os(iOS)
    final class IOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
        func application(
            _: UIApplication,
            didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            UNUserNotificationCenter.current().delegate = self
            return true
        }

        func userNotificationCenter(
            _: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            guard TrialReminderNotification.opensManageSubscriptions(response.notification.request) else { return }
            AppStoreSubscriptionManagementRouter.shared.present()
        }

        func userNotificationCenter(
            _: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            guard TrialReminderNotification.opensManageSubscriptions(notification.request) else { return [] }
            return [.banner, .sound]
        }
    }
#endif
