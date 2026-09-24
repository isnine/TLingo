//
//  SelectionPopupResizeGrabber.swift
//  TLingo
//
//  Created by AI Assistant on 2026/05/17.
//

#if os(macOS)
    import AppKit
    import ShareCore
    import SwiftUI

    /// Bottom-right corner drag handle for the text-selection translation
    /// popup. Reports cumulative drag deltas (relative to the gesture's
    /// start) so the controller can resize the `NSPanel` while keeping the
    /// top-left anchor pinned. On release, asks the controller to persist
    /// the new size to `AppPreferences`.
    struct SelectionPopupResizeGrabber: View {
        var onDrag: (CGSize) -> Void
        var onEnded: () -> Void

        @State private var lastTranslation: CGSize = .zero
        @State private var isDragging: Bool = false
        @State private var isHovering: Bool = false
        @State private var cursorPushed: Bool = false

        var body: some View {
            ZStack {
                // Diagonal grip lines, subtle.
                Path { path in
                    path.move(to: CGPoint(x: 12, y: 2))
                    path.addLine(to: CGPoint(x: 2, y: 12))
                    path.move(to: CGPoint(x: 12, y: 7))
                    path.addLine(to: CGPoint(x: 7, y: 12))
                }
                .stroke(
                    Color.secondary.opacity(isHovering || isDragging ? 0.7 : 0.4),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
            }
            .frame(width: 14, height: 14)
            .padding(5)
            .tlingoGlassSurface(
                cornerRadius: 8,
                tint: Color.secondary.opacity(isHovering || isDragging ? 0.16 : 0.08),
                interactive: true,
                fallbackTint: Color.primary.opacity(isHovering || isDragging ? 0.10 : 0.06),
                fallbackStroke: Color.secondary.opacity(isHovering || isDragging ? 0.32 : 0.18)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                // SwiftUI can fire repeated true/true on re-layout; ignore
                // duplicates to avoid leaking NSCursor stack frames.
                guard hovering != isHovering else { return }
                isHovering = hovering
                if hovering {
                    NSCursor.crosshair.push()
                    cursorPushed = true
                } else if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .onDisappear {
                if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging { isDragging = true }
                        // SwiftUI translation is cumulative from drag start;
                        // forward the incremental delta so the controller
                        // can add it to the live panel frame.
                        let deltaX = value.translation.width - lastTranslation.width
                        // SwiftUI Y grows downward, AppKit panel Y grows
                        // upward — controller keeps top-left fixed so a
                        // downward drag grows height.
                        let deltaY = value.translation.height - lastTranslation.height
                        lastTranslation = value.translation
                        onDrag(CGSize(width: deltaX, height: deltaY))
                    }
                    .onEnded { _ in
                        lastTranslation = .zero
                        isDragging = false
                        onEnded()
                    }
            )
            .padding(2)
            .accessibilityLabel(Text("Resize popup"))
        }
    }
#endif
