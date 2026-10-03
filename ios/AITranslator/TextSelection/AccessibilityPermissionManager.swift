//
//  AccessibilityPermissionManager.swift
//  TLingo
//
//  Manages Accessibility permission state with polling.
//

#if os(macOS) && (DIRECT_DISTRIBUTION || TLINGO_HELPER)
    import AppKit
    import Combine
    import PermissionFlow

    @MainActor
    final class AccessibilityPermissionManager: ObservableObject {
        @Published private(set) var isAccessibilityGranted = false
        @Published private(set) var showsReplacementHint = false
        private var pollTimer: Timer?
        private var permissionFlow: PermissionFlowController?
        private var dragMonitor: Any?
        private var dragReleaseTimer: Timer?
        private var permissionCheckTask: Task<Void, Never>?

        init() {
            isAccessibilityGranted = AXIsProcessTrusted()
        }

        /// Open System Settings > Accessibility.
        func openAccessibilitySettings() {
            permissionFlow = permissionFlow ?? PermissionFlowController(
                configuration: .init(promptForAccessibilityTrust: false)
            )
            permissionFlow?.authorize(
                pane: .accessibility,
                suggestedAppURLs: [Bundle.main.bundleURL]
            )
            startMonitoringDragRelease()
            startPolling()
        }

        func startPolling() {
            guard pollTimer == nil else { return }
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let granted = AXIsProcessTrusted()
                    if granted != self.isAccessibilityGranted {
                        self.isAccessibilityGranted = granted
                    }
                    if granted {
                        self.showsReplacementHint = false
                        self.stopMonitoringDragRelease()
                        self.pollTimer?.invalidate()
                        self.pollTimer = nil
                        self.permissionFlow?.closePanel(returnToPreviousApp: true)
                        self.permissionFlow = nil
                    }
                }
            }
        }

        func stopPolling() {
            pollTimer?.invalidate()
            pollTimer = nil
            stopMonitoringDragRelease()
            permissionFlow?.closePanel()
            permissionFlow = nil
        }

        private func startMonitoringDragRelease() {
            guard dragMonitor == nil else { return }
            dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
                guard event.window.map({ String(describing: type(of: $0)).contains("FloatingDropPanel") }) == true else {
                    return event
                }
                Task { @MainActor in
                    self?.waitForDragRelease()
                }
                return event
            }
        }

        private func waitForDragRelease() {
            showsReplacementHint = false
            permissionCheckTask?.cancel()
            dragReleaseTimer?.invalidate()
            dragReleaseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                timer.invalidate()
                Task { @MainActor in
                    guard let self else { return }
                    self.dragReleaseTimer = nil
                    self.permissionCheckTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled, !AXIsProcessTrusted() else { return }
                        self.showsReplacementHint = true
                    }
                }
            }
        }

        private func stopMonitoringDragRelease() {
            if let dragMonitor {
                NSEvent.removeMonitor(dragMonitor)
                self.dragMonitor = nil
            }
            dragReleaseTimer?.invalidate()
            dragReleaseTimer = nil
            permissionCheckTask?.cancel()
            permissionCheckTask = nil
        }
    }
#endif
