//
//  TranslationPopupPanel.swift
//  TLingo
//
//  Floating non-activating panel for text selection translation results.
//

#if os(macOS)
    import AppKit
    import ShareCore

    final class TranslationPopupPanel: NSPanel {
        init(contentRect: NSRect) {
            super.init(
                contentRect: contentRect,
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
                backing: .buffered,
                defer: true
            )

            level = .floating
            isOpaque = false
            backgroundColor = .clear
            hidesOnDeactivate = false
            isMovableByWindowBackground = true
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            isReleasedWhenClosed = false
            minSize = AppPreferences.selectionPopupMinSize
            maxSize = AppPreferences.selectionPopupMaxSize

            contentView?.wantsLayer = true
            contentView?.layer?.cornerRadius = 12
            contentView?.layer?.masksToBounds = true
        }

        override var canBecomeKey: Bool { true }

        override func sendEvent(_ event: NSEvent) {
            if event.type == .leftMouseDown {
                if !isKeyWindow { makeKey() }
            }
            super.sendEvent(event)
        }
    }
#endif
