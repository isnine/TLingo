//
//  TriggerIconController.swift
//  TLingo
//
//  Manages trigger icon lifecycle: show near cursor, hover/click to translate, auto-dismiss.
//

#if os(macOS) && (DIRECT_DISTRIBUTION || TLINGO_HELPER)
    import AppKit
    #if !TLINGO_HELPER
        import ShareCore
    #endif
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
                    #if TLINGO_HELPER
                        .glassEffect(.regular.tint(Color.accentColor.opacity(0.18)).interactive(), in: .circle)
                    #else
                        .tlingoGlassCircle(
                            tint: Color.accentColor.opacity(0.18),
                            interactive: true,
                            fallbackTint: Color.primary.opacity(0.10),
                            fallbackStroke: Color.secondary.opacity(0.36)
                        )
                    #endif
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

    // MARK: - TriggerActionToolbar

    private struct TriggerActionToolbar: View {
        static let visibleActionCount = 3

        let actions: [TextPopupRequest.ActionSummary]
        let onSelect: (String) -> Void
        let onHover: (Bool) -> Void

        var body: some View {
            HStack(spacing: 2) {
                ForEach(actions.prefix(Self.visibleActionCount), id: \.id) { action in
                    Button {
                        onSelect(action.id)
                    } label: {
                        Image(systemName: action.symbol)
                            .frame(width: 30, height: 28)
                            .contentShape(.rect)
                    }
                    .help(action.name)
                    .accessibilityLabel(action.name)
                }
                if actions.count > Self.visibleActionCount {
                    Menu {
                        ForEach(actions.dropFirst(Self.visibleActionCount), id: \.id) { action in
                            Button {
                                onSelect(action.id)
                            } label: {
                                Label(action.name, systemImage: action.symbol)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 30, height: 28)
                            .contentShape(.rect)
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(Text("More Actions"))
                    .accessibilityLabel(Text("More Actions"))
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            #if TLINGO_HELPER
                .glassEffect(.regular, in: .capsule)
            #else
                .tlingoGlassCapsule(.chrome)
            #endif
            .padding(2)
            .onHover(perform: onHover)
        }
    }

    /// The toolbar's panel is never key, so its buttons must act on the first click.
    private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
            true
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
        required init?(coder _: NSCoder) {
            fatalError()
        }

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
        /// Clicking the dot shows these as a toolbar; when empty it translates with the selected action.
        var actions: [TextPopupRequest.ActionSummary] = []
        /// The action ID is nil when the request should use TLingo's selected action.
        var onTranslateRequested: ((SelectionTextGrabber.Selection, String?) -> Void)?
        var onDismissed: (() -> Void)?
        var onCaptureFailed: (() -> Void)?
        var onCaptureStarted: (() -> Void)?
        var onCaptureCancelled: (() -> Void)?

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
                guard let self else { return }
                cancelAutoDismissTimer()
                onTriggerHovered?()
                // Hovering the dot is enough to reveal the actions; a click is not required.
                if !actions.isEmpty {
                    showActionToolbar()
                }
            }
            trackingView.onMouseExited = { [weak self] in
                self?.startAutoDismissTimer()
            }
            trackingView.onMouseDown = { [weak self] in
                guard let self else { return }
                if actions.isEmpty {
                    triggerTranslation(actionID: nil)
                } else {
                    showActionToolbar()
                }
            }

            panel.contentView = trackingView

            let offset: CGFloat = 4
            var x = point.x + offset
            var y = point.y - offset - size

            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
                let visibleFrame = screen.visibleFrame
                if x + size > visibleFrame.maxX {
                    x = point.x - size - offset
                }
                if y + size > visibleFrame.maxY {
                    y = point.y - size - offset
                }
                if x < visibleFrame.minX {
                    x = visibleFrame.minX
                }
                if y < visibleFrame.minY {
                    y = visibleFrame.minY
                }
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

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    panel.contentView = nil
                    panel.close()
                    // A new icon may have been shown during the fade-out; leave it alone.
                    guard let self, self.panel === panel else { return }
                    self.cleanup()
                    self.onDismissed?()
                }
            }
        }

        func dismissSilently() {
            let wasCapturing = grabTask != nil
            grabTask?.cancel()
            grabTask = nil
            if wasCapturing {
                onCaptureCancelled?()
            }
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

        private func showActionToolbar() {
            guard let panel else { return }
            cancelAllTimers()
            trackingView = nil

            let hostingView = FirstMouseHostingView(rootView: TriggerActionToolbar(
                actions: actions,
                onSelect: { [weak self] actionID in
                    self?.triggerTranslation(actionID: actionID)
                },
                onHover: { [weak self] isHovering in
                    if isHovering {
                        self?.cancelAutoDismissTimer()
                    } else {
                        self?.startAutoDismissTimer()
                    }
                }
            ))
            let size = hostingView.fittingSize
            hostingView.frame = NSRect(origin: .zero, size: size)
            panel.contentView = hostingView

            // Keep the dot's top-left corner so the toolbar grows from where the user clicked.
            var frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
            if let screen = panel.screen ?? NSScreen.main {
                let visibleFrame = screen.visibleFrame
                frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
            }
            panel.setFrame(frame, display: true)
        }

        private func triggerTranslation(actionID: String?) {
            guard let point = anchorPoint, let panel else {
                onCaptureFailed?()
                return
            }
            cancelAllTimers()

            panel.contentView = nil
            panel.close()
            cleanup()
            onCaptureStarted?()

            grabTask = Task { @MainActor [weak self] in
                let selection = await SelectionTextGrabber.grab(near: point)
                guard !Task.isCancelled else { return }
                self?.grabTask = nil
                guard let selection,
                      !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    self?.onCaptureFailed?()
                    return
                }
                self?.onTranslateRequested?(selection, actionID)
            }
        }
    }
#endif
