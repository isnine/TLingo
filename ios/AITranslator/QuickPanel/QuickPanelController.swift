//
//  QuickPanelController.swift
//  TLingo
//
//  Spotlight-style translation panel summoned to the center of the active screen.
//

#if os(macOS)
    import AppKit
    import SwiftUI

    @MainActor
    final class QuickPanelController {
        static let shared = QuickPanelController()

        static let width: CGFloat = 760

        private var panel: QuickPanelWindow?
        private var resignKeyObserver: NSObjectProtocol?

        private init() {}

        var isVisible: Bool {
            panel?.isVisible == true
        }

        func toggle() {
            if isVisible {
                hide()
            } else {
                show()
            }
        }

        func show() {
            let panel = panel ?? makePanel()
            self.panel = panel
            position(panel)
            panel.makeKeyAndOrderFront(nil)
            focusInput(in: panel)
            NotificationCenter.default.post(name: .quickPanelDidShow, object: nil)
        }

        private func focusInput(in panel: NSPanel) {
            DispatchQueue.main.async {
                guard let textView = panel.contentView.flatMap(Self.firstTextView(in:)) else { return }
                panel.makeFirstResponder(textView)
                textView.selectAll(nil)
            }
        }

        private static func firstTextView(in view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView { return textView }
            for subview in view.subviews {
                if let textView = firstTextView(in: subview) { return textView }
            }
            return nil
        }

        func hide() {
            panel?.orderOut(nil)
        }

        /// Resizes the panel to its SwiftUI content while keeping the top edge in place.
        func updateContentHeight(_ height: CGFloat) {
            guard let panel, height > 0, abs(panel.frame.height - height) > 0.5 else { return }
            var frame = panel.frame
            frame.origin.y += frame.height - height
            frame.size.height = height
            panel.setFrame(frame, display: true)
        }

        private func makePanel() -> QuickPanelWindow {
            let panel = QuickPanelWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160))
            let hostingView = NSHostingView(rootView: QuickPanelView(onClose: { [weak self] in self?.hide() }))
            // The controller owns the frame so growth keeps the top edge fixed instead of the bottom.
            hostingView.sizingOptions = []
            panel.contentView = hostingView

            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Sheets (model picker, consent) take key status; keep the panel behind them.
                    guard let self, let panel = self.panel, panel.attachedSheet == nil else { return }
                    self.hide()
                }
            }
            return panel
        }

        private func position(_ panel: NSPanel) {
            let mouseLocation = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
            guard let visibleFrame = screen?.visibleFrame else { return }
            // Like Spotlight, the top edge sits in the upper part of the screen so results grow downward.
            let top = visibleFrame.maxY - visibleFrame.height * 0.22
            panel.setFrameOrigin(NSPoint(x: visibleFrame.midX - Self.width / 2, y: top - panel.frame.height))
        }
    }

    final class QuickPanelWindow: NSPanel {
        init(contentRect: NSRect) {
            super.init(
                contentRect: contentRect,
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered,
                defer: true
            )
            level = .floating
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            hidesOnDeactivate = false
            isMovableByWindowBackground = true
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            isReleasedWhenClosed = false
        }

        override var canBecomeKey: Bool { true }

        override func cancelOperation(_: Any?) {
            orderOut(nil)
        }
    }

    extension Notification.Name {
        static let quickPanelDidShow = Notification.Name("quickPanelDidShow")
    }
#endif
