//
//  AccessibilityGrabber.swift
//  TLingo
//
//  Text selection via macOS Accessibility API (Tier 1).
//

#if os(macOS)
    import AppKit
    import ApplicationServices

    enum AccessibilityGrabber {
        struct Selection {
            let text: String
            fileprivate let element: AXUIElement
        }

        /// Read the selected text from the frontmost application using the Accessibility API.
        /// Validates that the click occurred near the focused element to filter stale selections.
        @MainActor
        static func grabSelectedText(near clickPoint: CGPoint? = nil) -> String? {
            grabSelection(near: clickPoint)?.text
        }

        @MainActor
        static func grabSelection(near clickPoint: CGPoint? = nil) -> Selection? {
            guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }

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
            else { return nil }

            let focusedElement = unsafeBitCast(focusedRef, to: AXUIElement.self)

            var selectedValue: CFTypeRef?
            let selectResult = AXUIElementCopyAttributeValue(
                focusedElement,
                kAXSelectedTextAttribute as CFString,
                &selectedValue
            )
            guard selectResult == .success, let text = selectedValue as? String, !text.isEmpty else {
                return nil
            }

            if let clickPoint {
                var positionValue: CFTypeRef?
                var sizeValue: CFTypeRef?
                AXUIElementCopyAttributeValue(focusedElement, kAXPositionAttribute as CFString, &positionValue)
                AXUIElementCopyAttributeValue(focusedElement, kAXSizeAttribute as CFString, &sizeValue)

                if let positionValue = axValue(from: positionValue),
                   let sizeValue = axValue(from: sizeValue)
                {
                    var position = CGPoint.zero
                    var size = CGSize.zero
                    AXValueGetValue(positionValue, .cgPoint, &position)
                    AXValueGetValue(sizeValue, .cgSize, &size)

                    // NSEvent.mouseLocation uses bottom-left origin; AX uses top-left origin
                    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
                    let axClickY = screenHeight - clickPoint.y

                    let tolerance: CGFloat = 20
                    let expandedRect = CGRect(
                        x: position.x - tolerance,
                        y: position.y - tolerance,
                        width: size.width + tolerance * 2,
                        height: size.height + tolerance * 2
                    )

                    if !expandedRect.contains(CGPoint(x: clickPoint.x, y: axClickY)) {
                        return nil
                    }
                }
            }

            return Selection(text: text, element: focusedElement)
        }

        static func replaceSelectedText(_ text: String, in selection: Selection) -> Bool {
            var isSettable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(
                selection.element,
                kAXSelectedTextAttribute as CFString,
                &isSettable
            ) == .success, isSettable.boolValue
            else { return false }

            return AXUIElementSetAttributeValue(
                selection.element,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            ) == .success
        }

        private static func axValue(from value: CFTypeRef?) -> AXValue? {
            guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
                return nil
            }
            return unsafeBitCast(value, to: AXValue.self)
        }
    }
#endif
