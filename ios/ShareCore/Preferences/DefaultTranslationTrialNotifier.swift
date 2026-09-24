//
//  DefaultTranslationTrialNotifier.swift
//  ShareCore
//
//  Cross-process Darwin notification used by the TLingoTranslation system
//  extension to tell the main app that the user just exercised the default
//  translation extension. The onboarding view subscribes so the "Continue"
//  button lights up immediately instead of waiting for the next poll tick.
//

import Foundation

public enum DefaultTranslationTrialNotifier {
    public static let notificationName = "com.zanderwang.AITranslator.defaultTranslationTrialCompleted"

    /// Posts a Darwin notification observed by any process registered with the
    /// shared `CFNotificationCenter`. Safe to call from any thread.
    public static func post() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let cfName = CFNotificationName(notificationName as CFString)
        CFNotificationCenterPostNotification(center, cfName, nil, nil, true)
    }

    /// Registers a handler invoked on the main queue when the notification
    /// fires. Returns the underlying observer token; pass it to
    /// ``removeObserver(_:)`` to tear the registration down.
    @discardableResult
    public static func addObserver(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        startBridgingIfNeeded()
        return NotificationCenter.default.addObserver(
            forName: bridgedNotificationName,
            object: nil,
            queue: .main,
            using: { _ in handler() }
        )
    }

    public static func removeObserver(_ token: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(token)
    }

    // MARK: - Private

    private static let bridgedNotificationName = Notification.Name("DefaultTranslationTrialNotifier.bridged")

    private static let bridgeStarter: Void = {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let cfName = CFNotificationName(notificationName as CFString)
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                NotificationCenter.default.post(name: bridgedNotificationName, object: nil)
            },
            cfName.rawValue,
            nil,
            .deliverImmediately
        )
    }()

    private static func startBridgingIfNeeded() {
        _ = bridgeStarter
    }
}
