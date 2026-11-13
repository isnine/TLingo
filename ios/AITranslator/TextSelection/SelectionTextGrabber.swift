//
//  SelectionTextGrabber.swift
//  TLingo
//
//  Resolves the currently selected text via AX → browser AppleScript → Cmd+C → menu bar Copy.
//

#if os(macOS) && TLINGO_HELPER
    import AppKit

    @MainActor
    enum SelectionTextGrabber {
        struct Selection {
            let text: String
        }

        static func grab(near point: CGPoint?) async -> Selection? {
            // Wait briefly so the target app's AX selection state is updated after mouse-up.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return nil }

            if let text = AccessibilityGrabber.grabSelectedText(near: point),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return Selection(text: text)
            }

            if let text = await AppleScriptGrabber.grabFromBrowser(),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return Selection(text: text)
            }

            let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            guard !Task.isCancelled, frontBundleID != "com.apple.finder" else { return nil }

            for usingMenuCopy in [false, true] {
                guard !Task.isCancelled else { return nil }
                if let text = await ClipboardGrabber.grabViaClipboard(usingMenuCopy: usingMenuCopy),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return Selection(text: text)
                }
            }
            return nil
        }
    }
#endif
