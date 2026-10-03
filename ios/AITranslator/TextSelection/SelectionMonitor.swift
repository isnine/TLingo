//
//  SelectionMonitor.swift
//  TLingo
//
//  Detects "looks like a text selection" gestures via global mouse monitoring.
//  Does not read text — that happens lazily when the user engages with the trigger icon.
//

#if os(macOS) && (DIRECT_DISTRIBUTION || TLINGO_HELPER)
    import AppKit
    import os

    private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "SelectionMonitor")

    @MainActor
    final class SelectionMonitor {
        var onTextSelected: ((CGPoint) -> Void)?
        var onMouseDown: ((CGPoint) -> Void)?
        var ignoredApplications: Set<String> = []

        private nonisolated(unsafe) var globalMonitor: Any?
        private nonisolated(unsafe) var mouseDownMonitor: Any?
        private nonisolated(unsafe) var localMonitor: Any?
        private var mouseDownPoint: CGPoint?
        private var isSuppressed = false
        private nonisolated(unsafe) var suppressTask: Task<Void, Never>?

        /// Screen-mirroring hosts and screenshot overlays, where mouse events are not text selection.
        private static let ignoredBundleIDs: Set<String> = [
            "com.apple.ScreenContinuity",
            "com.catchingnow.andfiles.fusionhost",
            "com.catchingnow.andfiles.phonescreenhost",
            "com.electron.lark.helper",
        ]

        deinit {
            if let monitor = mouseDownMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = globalMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
            }
            suppressTask?.cancel()
        }

        func start() {
            guard globalMonitor == nil else { return }
            logger.debug("Selection monitoring started")

            mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                let screenPoint = NSEvent.mouseLocation
                Task { @MainActor in
                    self?.mouseDownPoint = screenPoint
                    self?.onMouseDown?(screenPoint)
                }
            }

            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                let screenPoint = NSEvent.mouseLocation
                let clickCount = event.clickCount
                let isShiftClick = event.modifierFlags.contains(.shift)
                Task { @MainActor in
                    self?.handleMouseUp(at: screenPoint, clickCount: clickCount, isShiftClick: isShiftClick)
                }
            }

            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                guard !(event.window is TriggerIconPanel),
                      event.window.map({ String(describing: type(of: $0)).contains("FloatingDropPanel") }) != true
                else { return event }
                #if DIRECT_DISTRIBUTION
                    guard !(event.window is TranslationPopupPanel),
                          !(event.window?.sheetParent is TranslationPopupPanel)
                    else { return event }
                #endif
                let screenPoint = NSEvent.mouseLocation
                let eventType = event.type
                let clickCount = event.clickCount
                let isShiftClick = event.modifierFlags.contains(.shift)
                Task { @MainActor in
                    if eventType == .leftMouseDown {
                        self?.mouseDownPoint = screenPoint
                        self?.onMouseDown?(screenPoint)
                    } else {
                        self?.handleMouseUp(at: screenPoint, clickCount: clickCount, isShiftClick: isShiftClick)
                    }
                }
                return event
            }
        }

        func stop() {
            if let monitor = mouseDownMonitor {
                NSEvent.removeMonitor(monitor)
                mouseDownMonitor = nil
            }
            if let monitor = globalMonitor {
                NSEvent.removeMonitor(monitor)
                globalMonitor = nil
            }
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
                localMonitor = nil
            }
            suppressTask?.cancel()
            suppressTask = nil
            logger.debug("Selection monitoring stopped")
        }

        /// Suppress detection for 0.5s to prevent re-trigger after dismissal.
        func suppressBriefly() {
            isSuppressed = true
            suppressTask?.cancel()
            suppressTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.isSuppressed = false
            }
        }

        private func handleMouseUp(at point: CGPoint, clickCount: Int, isShiftClick: Bool) {
            guard !isSuppressed,
                  !Self.ignoredBundleIDs.union(ignoredApplications)
                  .contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
            else { return }

            var dragDistance: CGFloat = 0
            if let downPoint = mouseDownPoint {
                let dx = point.x - downPoint.x
                let dy = point.y - downPoint.y
                dragDistance = sqrt(dx * dx + dy * dy)
            }
            mouseDownPoint = nil

            let wasDragOrMultiClick = clickCount >= 2 || dragDistance > 5
            guard wasDragOrMultiClick || isShiftClick else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, !self.isSuppressed else { return }

                if let text = AccessibilityGrabber.grabSelectedText(near: point),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    self.onTextSelected?(point)
                    return
                }

                // AX unavailable (Chrome / Electron / etc). Require a deliberate drag
                // to avoid showing the icon for stray double-clicks on empty space.
                if dragDistance > 20 {
                    self.onTextSelected?(point)
                }
            }
        }
    }
#endif
