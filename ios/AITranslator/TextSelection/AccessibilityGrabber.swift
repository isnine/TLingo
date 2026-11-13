//
//  AccessibilityGrabber.swift
//  TLingo
//
//  Text selection via macOS Accessibility API (Tier 1).
//

#if os(macOS) && TLINGO_HELPER
    import AppKit
    import ApplicationServices

    enum AccessibilityGrabber {
        /// Caps every AX call this process makes; the 6 s default let a hung target app freeze
        /// the main thread on each selection.
        static let configureMessagingTimeout: Void = {
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        }()

        /// A focused element whose selection can be overwritten in place.
        struct ReplacementTarget {
            fileprivate let element: AXUIElement
            fileprivate let text: String
            fileprivate let range: CFRange
            let processIdentifier: pid_t

            @MainActor
            func selectionIsUnchanged() -> Bool {
                var current: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &current) == .success,
                      current as? String == text,
                      let currentRange = AccessibilityGrabber.selectionRange(of: element),
                      currentRange.location == range.location,
                      currentRange.length == range.length
                else { return false }
                let app = AXUIElementCreateApplication(processIdentifier)
                var focused: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                      let focused
                else { return false }
                return CFEqual(focused, element)
            }

            @MainActor
            func replace(with replacement: String) -> Bool {
                return AXUIElementSetAttributeValue(
                    element, kAXSelectedTextAttribute as CFString, replacement as CFString
                ) == .success
            }
        }

        enum SelectionState {
            case text(String, ReplacementTarget?)
            /// The focused element reports its selection and nothing is selected.
            case empty
            /// The app does not expose a selection near the click.
            case unavailable
        }

        /// Read the selected text from the frontmost application using the Accessibility API.
        @MainActor
        static func grabSelectedText(near clickPoint: CGPoint? = nil) -> String? {
            if case let .text(text, _) = selectionState(near: clickPoint) {
                return text
            }
            return nil
        }

        /// Validates that the click occurred near the focused element to filter stale selections.
        @MainActor
        static func selectionState(near clickPoint: CGPoint? = nil) -> SelectionState {
            _ = AccessibilityGrabber.configureMessagingTimeout
            guard let frontApp = NSWorkspace.shared.frontmostApplication else { return .unavailable }

            let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

            var focusedValue: CFTypeRef?
            let focusResult = AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue
            )
            guard focusResult == .success,
                  let focusedRef = focusedValue,
                  CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
            else { return .unavailable }

            let focusedElement = unsafeBitCast(focusedRef, to: AXUIElement.self)

            var selectedValue: CFTypeRef?
            let selectResult = AXUIElementCopyAttributeValue(
                focusedElement,
                kAXSelectedTextAttribute as CFString,
                &selectedValue
            )
            guard selectResult == .success, let text = selectedValue as? String else {
                return .unavailable
            }

            if let clickPoint, let frame = frame(of: focusedElement),
               !frame.insetBy(dx: -20, dy: -20).contains(axPoint(clickPoint))
            {
                return .unavailable
            }
            guard !text.isEmpty else { return .empty }

            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(focusedElement, kAXSelectedTextAttribute as CFString, &settable)
            let target: ReplacementTarget?
            if settable.boolValue, let range = selectionRange(of: focusedElement) {
                target = ReplacementTarget(
                    element: focusedElement, text: text, range: range, processIdentifier: frontApp.processIdentifier
                )
            } else {
                target = nil
            }
            return .text(text, target)
        }

        private static func selectionRange(of element: AXUIElement) -> CFRange? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXValueGetTypeID()
            else { return nil }
            var range = CFRange()
            guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else { return nil }
            return range
        }

        /// What a drag started on: the role under the pointer and its window's frame at that moment.
        struct DragOrigin {
            fileprivate let role: String?
            fileprivate let window: AXUIElement?
            fileprivate let windowFrame: CGRect?

            /// Controls and items whose drags never select text.
            private static let nonTextRoles: Set<String> = [
                kAXButtonRole, kAXScrollBarRole, kAXSliderRole, kAXValueIndicatorRole, kAXSplitterRole,
                kAXImageRole, kAXMenuBarRole, kAXMenuBarItemRole, kAXMenuItemRole, kAXMenuButtonRole,
                kAXPopUpButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXTabGroupRole, kAXToolbarRole,
                kAXDockItemRole, kAXHandleRole, kAXGrowAreaRole, kAXIncrementorRole, kAXColorWellRole,
            ]

            /// False for drags that moved or resized the window, or began on a non-text control.
            @MainActor
            var mayHaveSelectedText: Bool {
                if let role, Self.nonTextRoles.contains(role) {
                    return false
                }
                if let window, let windowFrame, AccessibilityGrabber.frame(of: window) != windowFrame {
                    return false
                }
                return true
            }
        }

        @MainActor
        static func dragOrigin(at point: CGPoint) -> DragOrigin {
            _ = AccessibilityGrabber.configureMessagingTimeout
            let position = axPoint(point)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                AXUIElementCreateSystemWide(), Float(position.x), Float(position.y), &hit
            ) == .success, let hit else { return DragOrigin(role: nil, window: nil, windowFrame: nil) }

            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &roleValue)
            let role = roleValue as? String

            var window: AXUIElement? = role == kAXWindowRole ? hit : nil
            var windowValue: CFTypeRef?
            if window == nil,
               AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &windowValue) == .success,
               let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID()
            {
                window = unsafeBitCast(windowValue, to: AXUIElement.self)
            }
            return DragOrigin(role: role, window: window, windowFrame: window.flatMap(frame))
        }

        /// NSEvent.mouseLocation uses bottom-left origin; AX uses top-left origin.
        private static func axPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
        }

        private static func frame(of element: AXUIElement) -> CGRect? {
            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
            guard let positionValue = axValue(from: positionValue), let sizeValue = axValue(from: sizeValue)
            else { return nil }
            var position = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(positionValue, .cgPoint, &position)
            AXValueGetValue(sizeValue, .cgSize, &size)
            return CGRect(origin: position, size: size)
        }

        private static func axValue(from value: CFTypeRef?) -> AXValue? {
            guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
                return nil
            }
            return unsafeBitCast(value, to: AXValue.self)
        }
    }
#endif
