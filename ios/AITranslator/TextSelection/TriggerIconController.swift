//
//  TriggerIconController.swift
//  TLingo
//
//  Manages trigger icon lifecycle: show near cursor, hover/click to translate, auto-dismiss.
//

#if os(macOS)
    import AppKit
    import ShareCore
    import SwiftUI

    // MARK: - TriggerIconGlassView

    private struct TriggerIconGlassView: View {
        let isHovering: Bool

        var body: some View {
            ZStack {
                if isHovering {
                    Image(systemName: "translate")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: TriggerIconPanel.size, height: TriggerIconPanel.size)
                        .tlingoGlassCircle(
                            tint: Color.accentColor.opacity(0.18),
                            interactive: true,
                            fallbackTint: Color.primary.opacity(0.10),
                            fallbackStroke: Color.secondary.opacity(0.36)
                        )
                } else {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: TriggerIconPanel.size, height: TriggerIconPanel.size)
            .scaleEffect(isHovering ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .accessibilityLabel(Text("Translate selected text"))
        }
    }

    @MainActor
    final class TriggerTrackingView: NSView {
        var onMouseEntered: (() -> Void)?
        var onMouseExited: (() -> Void)?
        var onMouseDown: (() -> Void)?

        private var trackingArea: NSTrackingArea?
        private let hostingView: NSHostingView<TriggerIconGlassView>
        private var isHovering = false {
            didSet {
                guard oldValue != isHovering else { return }
                hostingView.rootView = TriggerIconGlassView(isHovering: isHovering)
            }
        }

        override init(frame frameRect: NSRect) {
            hostingView = NSHostingView(rootView: TriggerIconGlassView(isHovering: false))
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            hostingView.frame = bounds
            hostingView.autoresizingMask = [.width, .height]
            addSubview(hostingView)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea {
                removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
            true
        }

        override func mouseEntered(with _: NSEvent) {
            isHovering = true
            onMouseEntered?()
        }

        override func mouseExited(with _: NSEvent) {
            isHovering = false
            onMouseExited?()
        }

        override func mouseDown(with _: NSEvent) {
            onMouseDown?()
        }
    }

    // MARK: - TriggerIconController

    @MainActor
    final class TriggerIconController {
        var onTriggerHovered: (() -> Void)?
        var onTranslateRequested: ((SelectionTextGrabber.Selection) -> Void)?
        var onDismissed: (() -> Void)?

        private var panel: TriggerIconPanel?
        private var trackingView: TriggerTrackingView?
        private var anchorPoint: CGPoint?
        private var autoDismissTimer: Timer?
        private var grabTask: Task<Void, Never>?

        func show(near point: CGPoint) {
            dismissSilently()

            anchorPoint = point

            let panel = TriggerIconPanel()
            let size = TriggerIconPanel.size
            let trackingView = TriggerTrackingView(frame: NSRect(x: 0, y: 0, width: size, height: size))

            trackingView.onMouseEntered = { [weak self] in
                self?.cancelAutoDismissTimer()
                self?.onTriggerHovered?()
            }
            trackingView.onMouseExited = { [weak self] in
                self?.startAutoDismissTimer()
            }
            trackingView.onMouseDown = { [weak self] in
                self?.triggerTranslation()
            }

            panel.contentView = trackingView

            let offset: CGFloat = 4
            var x = point.x + offset
            var y = point.y - offset - size

            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
                let visibleFrame = screen.visibleFrame
                if x + size > visibleFrame.maxX { x = point.x - size - offset }
                if y + size > visibleFrame.maxY { y = point.y - size - offset }
                if x < visibleFrame.minX { x = visibleFrame.minX }
                if y < visibleFrame.minY { y = visibleFrame.minY }
            }

            panel.setFrame(NSRect(x: x, y: y, width: size, height: size), display: true)
            panel.alphaValue = 0
            panel.orderFront(nil)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }

            self.panel = panel
            self.trackingView = trackingView

            startAutoDismissTimer()
        }

        func dismiss() {
            guard let panel else { return }
            cancelAllTimers()

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    panel.contentView = nil
                    panel.close()
                    // A new icon may have been shown during the fade-out; leave it alone.
                    guard let self, self.panel === panel else { return }
                    self.cleanup()
                    self.onDismissed?()
                }
            })
        }

        func dismissSilently() {
            grabTask?.cancel()
            grabTask = nil
            guard let panel else { return }
            cancelAllTimers()
            panel.contentView = nil
            panel.close()
            cleanup()
        }

        var isVisible: Bool {
            panel?.isVisible ?? false
        }

        private func cleanup() {
            panel = nil
            trackingView = nil
            anchorPoint = nil
        }

        // MARK: - Timers

        private func startAutoDismissTimer() {
            cancelAutoDismissTimer()
            autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.dismiss()
                }
            }
        }

        private func cancelAutoDismissTimer() {
            autoDismissTimer?.invalidate()
            autoDismissTimer = nil
        }

        private func cancelAllTimers() {
            cancelAutoDismissTimer()
        }

        private func triggerTranslation() {
            guard let point = anchorPoint else { return }
            cancelAllTimers()

            guard let panel else { return }
            panel.contentView = nil
            panel.close()
            cleanup()

            grabTask = Task { @MainActor [weak self] in
                guard let selection = await SelectionTextGrabber.grab(near: point),
                      !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !Task.isCancelled
                else { return }
                self?.grabTask = nil
                self?.onTranslateRequested?(selection)
            }
        }
    }
#endif
