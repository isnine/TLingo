#if os(macOS)
    import AppKit
    import ShareCore
    import SwiftUI

    @MainActor
    final class RealtimeFloatingCaptionWindowController: NSObject, NSWindowDelegate {
        static let visibilityDidChangeNotification = Notification.Name("TLingoRealtimeFloatingCaptionVisibilityDidChange")

        static var isOpen: Bool {
            shared.window?.isVisible == true
        }

        static func setVisible(_ isVisible: Bool, store: RealtimeSessionStore) {
            if isVisible {
                open(store: store)
            } else {
                close()
            }
        }

        static func open(store: RealtimeSessionStore) {
            shared.open(store: store)
        }

        static func close() {
            shared.close()
        }

        private static let windowIdentifier = "realtime-captions"
        private static let windowTitle = "Realtime Captions"
        private static let shared = RealtimeFloatingCaptionWindowController()

        private var window: NSPanel?
        private var configuredMode: RealtimeCaptionWindowMode?

        private var preferences: AppPreferences {
            AppPreferences.shared
        }

        private func open(store: RealtimeSessionStore) {
            closeOrphanWindows()

            let mode = preferences.realtimeCaptionWindowMode
            let shouldReposition = window == nil || configuredMode != mode
            let panel = window ?? makeWindow()
            panel.contentView = NSHostingView(rootView: RealtimeFloatingCaptionWindowView(store: store))
            configure(panel)
            if shouldReposition {
                positionForCurrentMode(panel)
            }
            configuredMode = mode
            window = panel
            panel.orderFrontRegardless()
            notifyVisibilityChanged()
        }

        private func close() {
            window?.close()
            window = nil
            configuredMode = nil
            notifyVisibilityChanged()
        }

        func windowWillClose(_ notification: Notification) {
            guard notification.object as? NSWindow === window else { return }
            window = nil
            Self.notifyVisibilityChanged()
        }

        private func makeWindow() -> NSPanel {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 150),
                styleMask: [.borderless, .nonactivatingPanel, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.delegate = self
            panel.isReleasedWhenClosed = false
            return panel
        }

        private func configure(_ panel: NSPanel) {
            panel.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
            panel.title = Self.windowTitle
            panel.hidesOnDeactivate = false
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.sharingType = preferences.realtimeCaptionPrivacyModeEnabled ? .none : .readOnly

            switch preferences.realtimeCaptionWindowMode {
            case .floating:
                configureFloating(panel)
            case .notch:
                configureNotch(panel)
            }
        }

        private func configureFloating(_ panel: NSPanel) {
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isMovableByWindowBackground = true
            panel.styleMask.insert(.resizable)
            panel.minSize = NSSize(width: 420, height: 120)
        }

        private func configureNotch(_ panel: NSPanel) {
            panel.isFloatingPanel = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isMovableByWindowBackground = false
            panel.styleMask.remove(.resizable)
            panel.minSize = NSSize(
                width: RealtimeNotchCaptionLayout.compactSize.width,
                height: RealtimeNotchCaptionLayout.compactSize.height
            )
        }

        private func positionForFirstOpen(_ panel: NSPanel) {
            guard let visibleFrame = NSScreen.main?.visibleFrame else { return }

            let frame = panel.frame
            let xPosition = visibleFrame.midX - frame.width / 2
            let yPosition = visibleFrame.minY + min(180, visibleFrame.height * 0.18)
            panel.setFrameOrigin(NSPoint(x: xPosition, y: yPosition))
        }

        private func positionForCurrentMode(_ panel: NSPanel) {
            switch preferences.realtimeCaptionWindowMode {
            case .floating:
                positionForFirstOpen(panel)
            case .notch:
                positionForNotch(panel)
            }
        }

        private func positionForNotch(_ panel: NSPanel) {
            guard let screen = targetScreenForNotch() else { return }

            let width = RealtimeNotchCaptionLayout.expandedSize.width
            let height = RealtimeNotchCaptionLayout.expandedSize.height
            let xPosition = RealtimeNotchCaptionLayout.originX(in: screen.frame, isCompact: false)
            let yPosition = (screen.frame.maxY - height).rounded()
            panel.setFrame(NSRect(x: xPosition, y: yPosition, width: width, height: height), display: true)
        }

        private func targetScreenForNotch() -> NSScreen? {
            RealtimeNotchDisplay.preferredScreen()
        }

        private func closeOrphanWindows() {
            for candidate in NSApp.windows where candidate !== window {
                if candidate.identifier?.rawValue == Self.windowIdentifier || candidate.title == Self.windowTitle {
                    candidate.close()
                }
            }
        }

        private func notifyVisibilityChanged() {
            Self.notifyVisibilityChanged()
        }

        private static func notifyVisibilityChanged() {
            NotificationCenter.default.post(name: visibilityDidChangeNotification, object: nil)
        }
    }
#endif
