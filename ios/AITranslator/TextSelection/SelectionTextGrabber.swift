//
//  SelectionTextGrabber.swift
//  TLingo
//
//  Resolves the currently selected text via AX → browser AppleScript → Cmd+C → menu bar Copy.
//

#if os(macOS)
    import AppKit

    @MainActor
    enum SelectionTextGrabber {
        struct Selection {
            let text: String
            let application: NSRunningApplication?
            let accessibilitySelection: AccessibilityGrabber.Selection?

            func replace(with text: String) async -> Bool {
                if let accessibilitySelection,
                   AccessibilityGrabber.replaceSelectedText(text, in: accessibilitySelection)
                {
                    return true
                }
                guard let application else { return false }
                return await ClipboardGrabber.replaceSelection(with: text, in: application)
            }
        }

        static func grab(near point: CGPoint?) async -> Selection? {
            // Wait briefly so the target app's AX selection state is updated after mouse-up.
            try? await Task.sleep(for: .milliseconds(50))

            let application = NSWorkspace.shared.frontmostApplication

            if let selection = AccessibilityGrabber.grabSelection(near: point),
               !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return Selection(
                    text: selection.text,
                    application: application,
                    accessibilitySelection: selection
                )
            }

            if let text = await AppleScriptGrabber.grabFromBrowser(),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return Selection(text: text, application: application, accessibilitySelection: nil)
            }

            let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            guard frontBundleID != "com.apple.finder" else { return nil }

            for usingMenuCopy in [false, true] {
                if let text = await ClipboardGrabber.grabViaClipboard(usingMenuCopy: usingMenuCopy),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return Selection(text: text, application: application, accessibilitySelection: nil)
                }
            }
            return nil
        }
    }
#endif
