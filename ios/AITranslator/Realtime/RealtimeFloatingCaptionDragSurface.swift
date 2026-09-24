#if os(macOS)
    import AppKit
    import SwiftUI

    private struct RealtimeCaptionResizeEdges: OptionSet {
        let rawValue: Int

        static let left = RealtimeCaptionResizeEdges(rawValue: 1 << 0)
        static let right = RealtimeCaptionResizeEdges(rawValue: 1 << 1)
        static let bottom = RealtimeCaptionResizeEdges(rawValue: 1 << 2)
        static let top = RealtimeCaptionResizeEdges(rawValue: 1 << 3)
    }

    struct RealtimeFloatingCaptionDragSurface: NSViewRepresentable {
        func makeNSView(context _: Context) -> NSView {
            let view = ResizeView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            return view
        }

        func updateNSView(_: NSView, context _: Context) {}

        private final class ResizeView: NSView {
            private static let edgeWidth: CGFloat = 28
            private var activeEdges: RealtimeCaptionResizeEdges = []
            private var initialWindowFrame = NSRect.zero
            private var initialMouseLocation = NSPoint.zero
            private var cursorTrackingArea: NSTrackingArea?

            override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
                true
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                window?.invalidateCursorRects(for: self)
            }

            override func setFrameSize(_ newSize: NSSize) {
                super.setFrameSize(newSize)
                window?.invalidateCursorRects(for: self)
            }

            override func hitTest(_ point: NSPoint) -> NSView? {
                guard bounds.contains(point), !resizeEdges(at: point).isEmpty else { return nil }
                return self
            }

            override func updateTrackingAreas() {
                if let cursorTrackingArea {
                    removeTrackingArea(cursorTrackingArea)
                }

                let trackingArea = NSTrackingArea(
                    rect: .zero,
                    options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
                    owner: self,
                    userInfo: nil
                )
                addTrackingArea(trackingArea)
                cursorTrackingArea = trackingArea

                super.updateTrackingAreas()
            }

            override func resetCursorRects() {
                let edgeWidth = Self.edgeWidth
                addCursorRect(NSRect(x: 0, y: 0, width: edgeWidth, height: bounds.height), cursor: .resizeLeftRight)
                addCursorRect(
                    NSRect(x: bounds.maxX - edgeWidth, y: 0, width: edgeWidth, height: bounds.height),
                    cursor: .resizeLeftRight
                )
                addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: edgeWidth), cursor: .resizeUpDown)
                addCursorRect(
                    NSRect(x: 0, y: bounds.maxY - edgeWidth, width: bounds.width, height: edgeWidth),
                    cursor: .resizeUpDown
                )
            }

            override func mouseMoved(with event: NSEvent) {
                updateCursor(for: event)
            }

            override func cursorUpdate(with event: NSEvent) {
                updateCursor(for: event)
            }

            override func mouseExited(with _: NSEvent) {
                NSCursor.arrow.set()
            }

            override func mouseDown(with event: NSEvent) {
                activeEdges = resizeEdges(at: convert(event.locationInWindow, from: nil))
                initialWindowFrame = window?.frame ?? .zero
                initialMouseLocation = NSEvent.mouseLocation
                updateCursor(for: activeEdges)
            }

            override func mouseDragged(with _: NSEvent) {
                guard let window, !activeEdges.isEmpty else { return }

                let mouseLocation = NSEvent.mouseLocation
                let deltaX = mouseLocation.x - initialMouseLocation.x
                let deltaY = mouseLocation.y - initialMouseLocation.y
                var frame = initialWindowFrame

                if activeEdges.contains(.left) {
                    frame.origin.x = initialWindowFrame.origin.x + deltaX
                    frame.size.width = initialWindowFrame.width - deltaX
                }
                if activeEdges.contains(.right) {
                    frame.size.width = initialWindowFrame.width + deltaX
                }
                if activeEdges.contains(.bottom) {
                    frame.origin.y = initialWindowFrame.origin.y + deltaY
                    frame.size.height = initialWindowFrame.height - deltaY
                }
                if activeEdges.contains(.top) {
                    frame.size.height = initialWindowFrame.height + deltaY
                }

                constrain(&frame, for: window)
                window.setFrame(frame, display: true)
                updateCursor(for: activeEdges)
            }

            override func mouseUp(with event: NSEvent) {
                activeEdges = []
                updateCursor(for: event)
            }

            private func resizeEdges(at point: NSPoint) -> RealtimeCaptionResizeEdges {
                var edges: RealtimeCaptionResizeEdges = []
                let edgeWidth = Self.edgeWidth

                if point.x <= edgeWidth {
                    edges.insert(.left)
                } else if point.x >= bounds.maxX - edgeWidth {
                    edges.insert(.right)
                }

                if point.y <= edgeWidth {
                    edges.insert(.bottom)
                } else if point.y >= bounds.maxY - edgeWidth {
                    edges.insert(.top)
                }

                return edges
            }

            private func updateCursor(for event: NSEvent) {
                updateCursor(for: resizeEdges(at: convert(event.locationInWindow, from: nil)))
            }

            private func updateCursor(for edges: RealtimeCaptionResizeEdges) {
                cursor(for: edges).set()
            }

            private func cursor(for edges: RealtimeCaptionResizeEdges) -> NSCursor {
                guard !edges.isEmpty else { return .arrow }
                if edges.contains(.left) || edges.contains(.right) {
                    return .resizeLeftRight
                }
                return .resizeUpDown
            }

            private func constrain(_ frame: inout NSRect, for window: NSWindow) {
                let minimumSize = window.minSize

                if frame.width < minimumSize.width {
                    if activeEdges.contains(.left) {
                        frame.origin.x = initialWindowFrame.maxX - minimumSize.width
                    }
                    frame.size.width = minimumSize.width
                }

                if frame.height < minimumSize.height {
                    if activeEdges.contains(.bottom) {
                        frame.origin.y = initialWindowFrame.maxY - minimumSize.height
                    }
                    frame.size.height = minimumSize.height
                }

                guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }

                let inset: CGFloat = 16
                let maximumWidth = max(minimumSize.width, visibleFrame.width - inset * 2)
                let maximumHeight = max(minimumSize.height, visibleFrame.height - inset * 2)
                frame.size.width = min(frame.width, maximumWidth)
                frame.size.height = min(frame.height, maximumHeight)
                frame.origin.x = min(max(frame.origin.x, visibleFrame.minX + inset), visibleFrame.maxX - frame.width - inset)
                frame.origin.y = min(max(frame.origin.y, visibleFrame.minY + inset), visibleFrame.maxY - frame.height - inset)
            }
        }
    }
#endif
