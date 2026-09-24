//
//  ScreenshotOCR.swift
//  TLingo
//
//  Screen region capture and clipboard image OCR for screenshot translation.
//

#if os(macOS)
    import AppKit
    import ScreenCaptureKit
    import ShareCore

    @MainActor
    enum ScreenshotOCR {
        /// Lets the user drag a screen region and returns its recognized text.
        static func captureAndRecognize() async -> String? {
            guard CGPreflightScreenCaptureAccess() else {
                CGRequestScreenCaptureAccess()
                return nil
            }
            guard let rect = await ScreenRegionSelector().selectRegion() else { return nil }
            // Let the window server remove the overlays before capturing.
            try? await Task.sleep(for: .milliseconds(100))
            guard let image = try? await SCScreenshotManager.captureImage(in: rect) else { return nil }
            return await recognize(image)
        }

        static func recognizeClipboardImage() async -> String? {
            guard let image = NSImage(pasteboard: .general)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return nil }
            return await recognize(image)
        }

        private static func recognize(_ image: CGImage) async -> String? {
            guard let text = try? await OCRTextRecognizer.recognizeText(in: image), !text.isEmpty else { return nil }
            return text
        }
    }

    /// Full-screen overlays on every display; resolves with the dragged rect in global display coordinates.
    @MainActor
    private final class ScreenRegionSelector {
        private var windows: [NSWindow] = []
        private var continuation: CheckedContinuation<CGRect?, Never>?

        func selectRegion() async -> CGRect? {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                for screen in NSScreen.screens {
                    let window = OverlayWindow(screen: screen)
                    window.contentView = SelectionView { [weak self] rect in self?.finish(rect) }
                    window.makeKeyAndOrderFront(nil)
                    windows.append(window)
                }
                NSApp.activate(ignoringOtherApps: true)
                NSCursor.crosshair.push()
            }
        }

        private func finish(_ screenRect: CGRect?) {
            NSCursor.pop()
            windows.forEach { $0.orderOut(nil) }
            windows.removeAll()
            let result = screenRect.flatMap { rect -> CGRect? in
                guard rect.width > 4, rect.height > 4, let mainHeight = NSScreen.screens.first?.frame.height
                else { return nil }
                return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
            }
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    private final class OverlayWindow: NSWindow {
        init(screen: NSScreen) {
            super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            level = .screenSaver
            isOpaque = false
            backgroundColor = .clear
            isReleasedWhenClosed = false
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            setFrame(screen.frame, display: false)
        }

        override var canBecomeKey: Bool { true }
    }

    private final class SelectionView: NSView {
        private let onFinish: (CGRect?) -> Void
        private var startPoint: CGPoint?
        private var currentRect: CGRect?

        init(onFinish: @escaping (CGRect?) -> Void) {
            self.onFinish = onFinish
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError() }

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            window?.makeFirstResponder(self)
        }

        override func draw(_: NSRect) {
            NSColor.black.withAlphaComponent(0.25).setFill()
            bounds.fill()
            guard let currentRect else { return }
            NSColor.clear.setFill()
            currentRect.fill(using: .copy)
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: currentRect).stroke()
        }

        override func mouseDown(with event: NSEvent) {
            startPoint = convert(event.locationInWindow, from: nil)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startPoint else { return }
            let point = convert(event.locationInWindow, from: nil)
            currentRect = CGRect(
                x: min(startPoint.x, point.x),
                y: min(startPoint.y, point.y),
                width: abs(point.x - startPoint.x),
                height: abs(point.y - startPoint.y)
            )
            needsDisplay = true
        }

        override func mouseUp(with _: NSEvent) {
            guard let currentRect, let window else { return onFinish(nil) }
            onFinish(window.convertToScreen(currentRect))
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onFinish(nil) }
        }
    }
#endif
