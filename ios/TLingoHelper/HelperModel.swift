import AppKit
import Combine
import os
import ServiceManagement

@MainActor
final class HelperModel: ObservableObject {
    enum State {
        case paused
        case needsAccessibility
        case ready

        var title: String {
            switch self {
            case .paused: String(localized: "Paused")
            case .needsAccessibility: String(localized: "Needs Accessibility Access")
            case .ready: String(localized: "Ready in other apps")
            }
        }

        var symbol: String {
            switch self {
            case .paused: "pause.circle"
            case .needsAccessibility: "exclamationmark.circle"
            case .ready: "text.cursor"
            }
        }
    }

    @Published private(set) var isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
    @Published private(set) var isAccessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var tlingoStatus = TLingoLink.status()
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

    let permissionManager = AccessibilityPermissionManager()
    private let selectionMonitor = SelectionMonitor()
    private let triggerIconController = TriggerIconController()
    private let notice = HelperNotice()
    private let logger = Logger(subsystem: "com.zanderwang.TLingoHelper", category: "Selection")
    private var cancellables: Set<AnyCancellable> = []
    private var sendTask: Task<Void, Never>?
    private var openPopup: (id: UUID, application: NSRunningApplication)?
    private var escapeMonitor: Any?

    private enum Keys {
        static let enabled = "selectionEnabled"
    }

    var state: State {
        if !isEnabled { return .paused }
        return isAccessibilityGranted ? .ready : .needsAccessibility
    }

    init() {
        selectionMonitor.ignoredApplications = [TLingoLink.bundleIdentifier, Bundle.main.bundleIdentifier ?? ""]
        selectionMonitor.onTextSelected = { [weak self] point in
            self?.triggerIconController.show(near: point)
        }
        selectionMonitor.onMouseDown = { [weak self] _ in
            self?.triggerIconController.dismissSilently()
            self?.notice.dismiss()
            // A click elsewhere closes TLingo's popup on its own; a click inside makes it key.
            self?.forgetOpenPopup()
        }
        triggerIconController.onDismissed = { [weak self] in
            self?.selectionMonitor.suppressBriefly()
        }
        triggerIconController.onCaptureFailed = { [weak self] in
            self?.showNotice(String(localized: "Couldn't read the selected text."))
        }
        triggerIconController.onTranslateRequested = { [weak self] selection in
            self?.translate(selection.text)
        }

        // AX trust has no change notification, and revocation must stop monitoring promptly.
        Timer.publish(every: 1.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshAccessibility() }
            .store(in: &cancellables)
        let workspace = NSWorkspace.shared.notificationCenter
        Publishers.Merge(
            workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification),
            workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)
        )
        .filter {
            ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier == TLingoLink.bundleIdentifier
        }
        .sink { [weak self] _ in self?.refreshTLingoStatus() }
        .store(in: &cancellables)

        updateMonitoring()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.enabled)
        updateMonitoring()
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refreshTLingoStatus() {
        let status = TLingoLink.status()
        if status != tlingoStatus {
            tlingoStatus = status
        }
    }

    private func refreshAccessibility() {
        let granted = AXIsProcessTrusted()
        guard granted != isAccessibilityGranted else { return }
        isAccessibilityGranted = granted
        updateMonitoring()
    }

    private func updateMonitoring() {
        if state == .ready {
            selectionMonitor.start()
        } else {
            selectionMonitor.stop()
            triggerIconController.dismissSilently()
            forgetOpenPopup()
        }
    }

    // MARK: - Handoff

    private func translate(_ text: String) {
        let point = NSEvent.mouseLocation
        let request = TextPopupRequest.Translation(text: text, screenX: point.x, screenY: point.y)
        let previous = sendTask
        sendTask = Task {
            await previous?.value
            do {
                let application = try await TLingoLink.targetApplication()
                guard state == .ready else { return }
                try TLingoLink.send(.translate(request), to: application)
                rememberOpenPopup(request.id, in: application)
            } catch {
                showNotice(error.localizedDescription, near: point)
            }
            refreshTLingoStatus()
        }
    }

    private func rememberOpenPopup(_ id: UUID, in application: NSRunningApplication) {
        openPopup = (id, application)
        guard escapeMonitor == nil else { return }
        // TLingo's popup does not take focus, so Escape is only visible to this app.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.dismissOpenPopup() }
        }
    }

    private func dismissOpenPopup() {
        triggerIconController.dismissSilently()
        notice.dismiss()
        guard let openPopup else { return }
        forgetOpenPopup()
        try? TLingoLink.send(.dismiss(openPopup.id), to: openPopup.application)
    }

    private func forgetOpenPopup() {
        openPopup = nil
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    private func showNotice(_ message: String, near point: CGPoint = NSEvent.mouseLocation) {
        logger.error("Selection handoff failed: \(message, privacy: .public)")
        notice.show(message, near: point)
    }
}
