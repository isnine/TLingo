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

        var body: some View {
            PopoverEdgeResizeGrabber(
                cursor: .crosshair,
                accessibilityLabelKey: "Resize popup",
                onDragChanged: { translation in
                    // SwiftUI translation is cumulative from drag start;
                    // forward the incremental delta so the controller
                    // can add it to the live panel frame.
                    let deltaX = translation.width - lastTranslation.width
                    let deltaY = translation.height - lastTranslation.height
                    lastTranslation = translation
                    onDrag(CGSize(width: deltaX, height: deltaY))
                },
                onDragEnded: { _ in
                    lastTranslation = .zero
                    onEnded()
                }
            ) { isHovering, isDragging in
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
            }
            .padding(2)
        }
    }
#endif
