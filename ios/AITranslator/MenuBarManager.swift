//
//  MenuBarManager.swift
//  TLingo
//
//  Created by AI Assistant on 2025/12/31.
//

#if os(macOS)
    import AppKit
    import Combine
    import ShareCore
    import SwiftUI

    @MainActor
    enum MenuBarAction: Int, CaseIterable {
        case openMainWindow
        case toggleRealtimeCaptions
        case screenshotTranslate
        case selectionTranslate
        case clipboardTranslate
        case quit

        var title: String {
            switch self {
            case .openMainWindow:
                NSLocalizedString("Open Main Window", comment: "Status bar context menu item to open the main app window")
            case .toggleRealtimeCaptions:
                RealtimeCaptionVisibility.menuTitle(isVisible: RealtimeFloatingCaptionWindowController.isOpen)
            case .screenshotTranslate:
                HotKeyType.screenshotTranslate.displayName
            case .selectionTranslate:
                HotKeyType.selectionTranslate.displayName
            case .clipboardTranslate:
                HotKeyType.clipboardTranslate.displayName
            case .quit:
                NSLocalizedString("Quit TLingo", comment: "Status bar context menu item to quit the app")
            }
        }

        var systemImage: String {
            switch self {
            case .openMainWindow: "macwindow"
            case .toggleRealtimeCaptions: "text.bubble"
            case .screenshotTranslate: HotKeyType.screenshotTranslate.iconName
            case .selectionTranslate: HotKeyType.selectionTranslate.iconName
            case .clipboardTranslate: HotKeyType.clipboardTranslate.iconName
            case .quit: "power"
            }
        }

        var startsSection: Bool {
            self == .screenshotTranslate || self == .quit
        }
    }

    /// Manages the menu bar status item with popover UI for quick action execution
    @MainActor
    final class MenuBarManager: NSObject, ObservableObject {
        static let shared = MenuBarManager()

        private var statusItem: NSStatusItem?
        private var popover: NSPopover?
        private var popoverHostingController: NSHostingController<MenuBarPopoverView>?
        private var eventMonitor: Any?
        private var rightClickMonitor: Any?

        private let configurationStore: AppConfigurationStore

        override private init() {
            configurationStore = .shared
            super.init()

            // Listen for toggle popover notification from HotKeyManager
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleTogglePopover),
                name: .toggleMenuBarPopover,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func handleTogglePopover() {
            Task { @MainActor in
                togglePopover(nil)
            }
        }

        /// Setup the menu bar status item
        func setup() {
            guard statusItem == nil else { return }

            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

            if let button = statusItem?.button {
                button.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "AI Translator")
                button.image?.isTemplate = true
                button.action = #selector(togglePopover(_:))
                button.target = self
            }

            setupPopover()
            setupRightClickMenu()
            AppleTranslationWindowManager.shared.setup()
        }

        /// Remove the menu bar status item
        func teardown() {
            closePopover()
            AppleTranslationWindowManager.shared.teardown()
            if let rightClickMonitor = rightClickMonitor {
                NSEvent.removeMonitor(rightClickMonitor)
                self.rightClickMonitor = nil
            }
            if let statusItem = statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            popover = nil
            popoverHostingController = nil
        }

        private func setupPopover() {
            let contentView = MenuBarPopoverView { [weak self] in
                self?.closePopover()
            }

            let hostingController = NSHostingController(rootView: contentView)
            popoverHostingController = hostingController

            let popover = NSPopover()
            popover.contentSize = NSSize(
                width: AppPreferences.shared.menuBarPopoverWidth,
                height: AppPreferences.shared.menuBarPopoverHeight
            )
            popover.behavior = .transient
            popover.animates = true
            popover.contentViewController = hostingController

            self.popover = popover
        }

        // MARK: - Resize Support

        /// Maximum allowed popover height for the screen currently hosting the
        /// status item button. Falls back to the main screen, then to a sane
        /// constant if no screen is available.
        var maxPopoverHeight: CGFloat {
            let screen = statusItem?.button?.window?.screen ?? NSScreen.main
            let visible = screen?.visibleFrame.height ?? 900
            return max(AppPreferences.menuBarPopoverMinHeight, floor(visible * 0.8))
        }

        /// Maximum allowed popover width, clamped to 80% of the active
        /// screen's visible width so the popover never spills off the menu
        /// bar edge.
        var maxPopoverWidth: CGFloat {
            let screen = statusItem?.button?.window?.screen ?? NSScreen.main
            let visible = screen?.visibleFrame.width ?? 1440
            return max(AppPreferences.menuBarPopoverMinWidth, floor(visible * 0.8))
        }

        /// Called by the SwiftUI drag handle in `MenuBarPopoverView` to resize
        /// the popover live. Clamps to `[menuBarPopoverMinHeight, maxPopoverHeight]`.
        /// Pass `persist: true` only on gesture end — otherwise we'd hit
        /// `UserDefaults` synchronously on every drag pixel.
        func setPopoverHeight(_ requested: CGFloat, persist: Bool = true) {
            guard let popover else { return }
            let clamped = min(max(AppPreferences.menuBarPopoverMinHeight, requested), maxPopoverHeight)
            if abs(popover.contentSize.height - clamped) > 0.5 {
                popover.contentSize = NSSize(width: popover.contentSize.width, height: clamped)
            }
            AppPreferences.shared.setMenuBarPopoverHeight(clamped, persist: persist)
        }

        /// See `setPopoverHeight(_:persist:)` — same contract for width.
        func setPopoverWidth(_ requested: CGFloat, persist: Bool = true) {
            guard let popover else { return }
            let clamped = min(max(AppPreferences.menuBarPopoverMinWidth, requested), maxPopoverWidth)
            if abs(popover.contentSize.width - clamped) > 0.5 {
                popover.contentSize = NSSize(width: clamped, height: popover.contentSize.height)
            }
            AppPreferences.shared.setMenuBarPopoverWidth(clamped, persist: persist)
        }

        private func setupRightClickMenu() {
            rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self = self,
                      let button = self.statusItem?.button,
                      event.window == button.window
                else {
                    return event
                }

                self.closePopover()
                self.showContextMenu()
                return nil
            }
        }

        private func showContextMenu() {
            let menu = NSMenu()

            for action in MenuBarAction.allCases {
                if action.startsSection {
                    menu.addItem(.separator())
                }

                let item = NSMenuItem(title: action.title, action: #selector(menuItemSelected(_:)), keyEquivalent: "")
                item.target = self
                item.tag = action.rawValue
                menu.addItem(item)
            }

            if let button = statusItem?.button {
                // Temporarily set the menu and trigger it
                statusItem?.menu = menu
                button.performClick(nil)
                statusItem?.menu = nil
            }
        }

        @objc private func menuItemSelected(_ sender: NSMenuItem) {
            guard let action = MenuBarAction(rawValue: sender.tag) else { return }
            perform(action)
        }

        func perform(_ action: MenuBarAction) {
            closePopover()

            switch action {
            case .openMainWindow:
                AppDelegate.shared?.openMainWindow()
            case .toggleRealtimeCaptions:
                let shouldShow = RealtimeCaptionVisibility.toggledValue(
                    isVisible: RealtimeFloatingCaptionWindowController.isOpen
                )
                setRealtimeCaptionsVisible(shouldShow)
            case .screenshotTranslate:
                AppDelegate.shared?.translateScreenshot()
            case .selectionTranslate:
                AppDelegate.shared?.translateCurrentSelection()
            case .clipboardTranslate:
                AppDelegate.shared?.translateClipboard()
            case .quit:
                NSApp.terminate(nil)
            }
        }

        private func setRealtimeCaptionsVisible(_ isVisible: Bool) {
            let store = RealtimeSessionStore.shared
            store.showCaptions = isVisible

            if isVisible {
                RealtimeFloatingCaptionWindowController.open(store: store)
            } else {
                RealtimeFloatingCaptionWindowController.close()
            }
        }

        @objc private func togglePopover(_: Any?) {
            if let popover = popover, popover.isShown {
                closePopover()
            } else {
                showPopover()
            }
        }

        private func showPopover() {
            guard let button = statusItem?.button,
                  let popover = popover else { return }

            // Re-apply the persisted height clamped to the active screen's
            // available space, and persist the clamped value so the SwiftUI
            // frame in `MenuBarPopoverView` stays in sync — otherwise moving
            // from a large to a smaller display would shrink the NSPopover
            // window while the SwiftUI content kept the larger height,
            // clipping the bottom grabber.
            let clampedHeight = min(
                max(AppPreferences.menuBarPopoverMinHeight, AppPreferences.shared.menuBarPopoverHeight),
                maxPopoverHeight
            )
            AppPreferences.shared.setMenuBarPopoverHeight(clampedHeight)
            let clampedWidth = min(
                max(AppPreferences.menuBarPopoverMinWidth, AppPreferences.shared.menuBarPopoverWidth),
                maxPopoverWidth
            )
            AppPreferences.shared.setMenuBarPopoverWidth(clampedWidth)
            popover.contentSize = NSSize(width: clampedWidth, height: clampedHeight)

            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Ensure the popover window becomes key so keyboard events (Cmd+V) route here
            DispatchQueue.main.async {
                popover.contentViewController?.view.window?.makeKey()
            }

            // Notify that popover is now visible
            NotificationCenter.default.post(name: .menuBarPopoverDidShow, object: nil)

            // Setup event monitor to close popover when clicking outside
            if let existingMonitor = eventMonitor {
                NSEvent.removeMonitor(existingMonitor)
            }
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePopover()
            }
        }

        private func closePopover() {
            popover?.performClose(nil)
            // Mark current clipboard state so any copies made while
            // the popover was open won't trigger auto-paste on reopen.
            ClipboardMonitor.shared.recordInternalCopy()

            if let eventMonitor = eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }
    }

    extension Notification.Name {
        static let menuBarPopoverDidShow = Notification.Name("menuBarPopoverDidShow")
    }
#endif
