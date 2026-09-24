//
//  TriggerIconPanel.swift
//  TLingo
//
//  Tiny floating panel that hosts the trigger icon near the cursor.
//

#if os(macOS)
    import AppKit

    final class TriggerIconPanel: NSPanel {
        static let size: CGFloat = 32

        init() {
            let rect = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
            super.init(
                contentRect: rect,
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: true
            )

            isReleasedWhenClosed = false
            level = .floating
            isOpaque = false
            backgroundColor = .clear
            hidesOnDeactivate = false
            isMovableByWindowBackground = false
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }

        override var canBecomeKey: Bool { false }
    }
#endif
