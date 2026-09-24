//
//  ClipboardGrabber.swift
//  TLingo
//
//  Text selection via clipboard simulation (Tier 3).
//

#if os(macOS)
    import AppKit
    import os

    private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "ClipboardGrabber")

    enum ClipboardGrabber {
        private static let isGrabbing = OSAllocatedUnfairLock(initialState: false)

        /// Tag applied to synthetic CGEvents to distinguish from real user keypresses.
        private static let syntheticEventTag: Int64 = 0x544C_696E // "TLin"

        /// Grab selected text by simulating Cmd+C (or pressing the app's Copy menu item) and reading the clipboard.
        /// Saves and restores previous clipboard content unless externally modified.
        @MainActor static func grabViaClipboard(usingMenuCopy: Bool = false) async -> String? {
            guard isGrabbing.withLock({ val in
                if val { return false }
                val = true
                return true
            }) else { return nil }
            defer { isGrabbing.withLock { $0 = false } }

            let pasteboard = NSPasteboard.general
            let previousCount = pasteboard.changeCount

            // Save current clipboard contents with full type fidelity
            let savedItems: [[(NSPasteboard.PasteboardType, Data)]]? = pasteboard.pasteboardItems?.compactMap { item in
                let pairs = item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                    guard let data = item.data(forType: type) else { return nil }
                    return (type, data)
                }
                return pairs.isEmpty ? nil : pairs
            }

            // Detect real user Cmd+C during grab window
            let userCopied = OSAllocatedUnfairLock(initialState: false)
            let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command),
                   event.keyCode == 0x08, // 'c'
                   event.cgEvent?.getIntegerValueField(.eventSourceUserData) != syntheticEventTag
                {
                    userCopied.withLock { $0 = true }
                }
            }
            defer { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

            if usingMenuCopy {
                guard pressMenuBarCopy() else { return nil }
            } else {
                simulateCopy()
            }

            // Wait for clipboard to update (max 300ms)
            let deadline = Date().addingTimeInterval(0.3)
            while pasteboard.changeCount == previousCount, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }

            guard pasteboard.changeCount != previousCount else {
                return nil
            }

            let postCopyCount = pasteboard.changeCount

            // Filter file URL selections
            let isFileSelection = pasteboard.canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            )

            let text = isFileSelection ? nil : pasteboard.string(forType: .string)

            // Grace period for external Cmd+C
            try? await Task.sleep(for: .milliseconds(30))

            let externalModification = pasteboard.changeCount != postCopyCount || userCopied.withLock { $0 }

            // Restore previous clipboard only if no external modification
            if !externalModification {
                pasteboard.clearContents()
                if let savedItems {
                    let items = savedItems.map { itemTypes -> NSPasteboardItem in
                        let item = NSPasteboardItem()
                        for (type, data) in itemTypes {
                            item.setData(data, forType: type)
                        }
                        return item
                    }
                    pasteboard.writeObjects(items)
                }
            }

            guard let text, !text.isEmpty else {
                return nil
            }
            return text
        }

        @MainActor
        static func replaceSelection(with text: String, in application: NSRunningApplication) async -> Bool {
            let pasteboard = NSPasteboard.general
            let savedItems = pasteboard.pasteboardItems?.map { item in
                item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                    guard let data = item.data(forType: type) else { return nil }
                    return (type, data)
                }
            }

            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                restorePasteboard(savedItems)
                return false
            }
            let replacementCount = pasteboard.changeCount

            guard application.activate(options: []) else {
                restorePasteboard(savedItems)
                return false
            }

            let deadline = Date().addingTimeInterval(0.3)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier,
                  Date() < deadline
            {
                try? await Task.sleep(for: .milliseconds(20))
            }

            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
                restorePasteboard(savedItems)
                return false
            }

            simulatePaste()
            try? await Task.sleep(for: .milliseconds(100))

            if pasteboard.changeCount == replacementCount {
                restorePasteboard(savedItems)
            }
            return true
        }

        private static func simulateCopy() {
            let source = CGEventSource(stateID: .combinedSessionState)

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
            keyDown?.flags = .maskCommand
            keyDown?.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            keyDown?.post(tap: .cgSessionEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            keyUp?.post(tap: .cgSessionEventTap)
        }

        /// Presses the enabled Copy item (⌘C without extra modifiers) in the frontmost app's menu bar.
        private static func pressMenuBarCopy() -> Bool {
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let menuBar: AXUIElement = attribute(kAXMenuBarAttribute, of: AXUIElementCreateApplication(pid))
            else { return false }

            for barItem in children(of: menuBar) {
                for menu in children(of: barItem) {
                    for item in children(of: menu) {
                        guard attribute(kAXMenuItemCmdCharAttribute, of: item) as String? == "C",
                              attribute(kAXMenuItemCmdModifiersAttribute, of: item) as Int? == 0
                        else { continue }
                        guard attribute(kAXEnabledAttribute, of: item) as Bool? == true else { return false }
                        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                    }
                }
            }
            return false
        }

        private static func children(of element: AXUIElement) -> [AXUIElement] {
            attribute(kAXChildrenAttribute, of: element) ?? []
        }

        private static func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? T
        }

        private static func simulatePaste() {
            let source = CGEventSource(stateID: .combinedSessionState)

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            keyDown?.flags = .maskCommand
            keyDown?.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            keyDown?.post(tap: .cgSessionEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            keyUp?.post(tap: .cgSessionEventTap)
        }

        private static func restorePasteboard(
            _ savedItems: [[(NSPasteboard.PasteboardType, Data)]]?
        ) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard let savedItems else { return }
            let items = savedItems.map { itemTypes -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in itemTypes {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(items)
        }
    }
#endif
