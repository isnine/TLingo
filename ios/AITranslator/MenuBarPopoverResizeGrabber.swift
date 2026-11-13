//
//  MenuBarPopoverResizeGrabber.swift
//  TLingo
//
//  Created by AI Assistant on 2026/05/13.
//

#if os(macOS)
    import AppKit
    import ShareCore
    import SwiftUI

    /// Shared drag-and-cursor resize wrapper used by popover edge and corner handles.
    /// Encapsulates hover `NSCursor` stack safety and `onDisappear` cleanup so
    /// multiple grabbers don't duplicate cursor leak guards.
    struct PopoverEdgeResizeGrabber<Content: View>: View {
        let cursor: NSCursor
        let accessibilityLabelKey: LocalizedStringKey
        let onDragChanged: (CGSize) -> Void
        let onDragEnded: (CGSize) -> Void
        @ViewBuilder let content: (_ isHovering: Bool, _ isDragging: Bool) -> Content

        @State private var isDragging = false
        @State private var isHovering = false
        @State private var cursorPushed = false

        var body: some View {
            content(isHovering, isDragging)
                .contentShape(Rectangle())
                .onHover { hovering in
                    // SwiftUI can fire repeated true/true on re-layout; ignore
                    // duplicates to avoid leaking NSCursor stack frames.
                    guard hovering != isHovering else { return }
                    isHovering = hovering
                    if hovering {
                        cursor.push()
                        cursorPushed = true
                    } else if cursorPushed {
                        NSCursor.pop()
                        cursorPushed = false
                    }
                }
                .onDisappear {
                    // Hotkey-driven dismissal can remove this view while the
                    // pointer is still over the grabber, bypassing onHover(false).
                    if cursorPushed {
                        NSCursor.pop()
                        cursorPushed = false
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                            }
                            onDragChanged(value.translation)
                        }
                        .onEnded { value in
                            isDragging = false
                            onDragEnded(value.translation)
                        }
                )
                .accessibilityLabel(Text(accessibilityLabelKey))
        }
    }

    private enum MenuBarPopoverResizeAxis {
        case vertical
        case horizontal

        var cursor: NSCursor {
            switch self {
            case .vertical: .resizeUpDown
            case .horizontal: .resizeLeftRight
            }
        }

        var accessibilityLabelKey: LocalizedStringKey {
            switch self {
            case .vertical: "Resize popover"
            case .horizontal: "Resize popover width"
            }
        }
    }

    private struct MenuBarPopoverAxisResizeGrabber: View {
        @Environment(\.colorScheme) private var colorScheme
        @ObservedObject private var preferences = AppPreferences.shared
        @State private var dragStartDimension: CGFloat?

        @ThemeColors private var colors: AppColorPalette

        let axis: MenuBarPopoverResizeAxis

        private var currentDimension: CGFloat {
            switch axis {
            case .vertical: preferences.menuBarPopoverHeight
            case .horizontal: preferences.menuBarPopoverWidth
            }
        }

        private func delta(for translation: CGSize) -> CGFloat {
            switch axis {
            case .vertical: translation.height
            case .horizontal: translation.width
            }
        }

        private func applyDimension(_ dimension: CGFloat, persist: Bool) {
            switch axis {
            case .vertical:
                MenuBarManager.shared.setPopoverHeight(dimension, persist: persist)
            case .horizontal:
                MenuBarManager.shared.setPopoverWidth(dimension, persist: persist)
            }
        }

        var body: some View {
            PopoverEdgeResizeGrabber(
                cursor: axis.cursor,
                accessibilityLabelKey: axis.accessibilityLabelKey,
                onDragChanged: { translation in
                    let start = dragStartDimension ?? {
                        let initial = currentDimension
                        dragStartDimension = initial
                        return initial
                    }()
                    applyDimension(start + delta(for: translation), persist: false)
                },
                onDragEnded: { translation in
                    if let start = dragStartDimension {
                        applyDimension(start + delta(for: translation), persist: true)
                    }
                    dragStartDimension = nil
                }
            ) { isHovering, isDragging in
                let isActive = isHovering || isDragging
                ZStack {
                    switch axis {
                    case .vertical:
                        Capsule()
                            .fill(colors.textSecondary.opacity(isActive ? 0.42 : 0.22))
                            .frame(width: isActive ? 44 : 36, height: isActive ? 6 : 4)
                    case .horizontal:
                        Capsule()
                            .fill(colors.textSecondary.opacity(isActive ? 0.42 : 0.22))
                            .frame(width: isActive ? 6 : 4, height: isActive ? 44 : 36)
                            .opacity(isActive ? 1 : 0)
                    }
                }
                .frame(
                    maxWidth: axis == .vertical ? .infinity : nil,
                    maxHeight: axis == .horizontal ? .infinity : nil
                )
                .frame(
                    width: axis == .horizontal ? 10 : nil,
                    height: axis == .vertical ? 14 : nil
                )
                .animation(.easeOut(duration: 0.14), value: isActive)
            }
        }
    }

    /// Bottom-edge drag handle that lets the user enlarge the menu bar popover
    /// vertically when result content overflows the default 420pt height.
    struct MenuBarPopoverResizeGrabber: View {
        var body: some View {
            MenuBarPopoverAxisResizeGrabber(axis: .vertical)
        }
    }

    /// Right-edge drag handle that lets the user widen the menu bar popover horizontally.
    struct MenuBarPopoverWidthResizeGrabber: View {
        var body: some View {
            MenuBarPopoverAxisResizeGrabber(axis: .horizontal)
        }
    }
#endif
