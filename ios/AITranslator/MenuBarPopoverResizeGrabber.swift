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

    /// Bottom-edge drag handle that lets the user enlarge the menu bar popover
    /// vertically when result content overflows the default 420pt height.
    /// Tracks the cumulative drag delta against the height that was active when
    /// the gesture started, then forwards the new target height to
    /// `MenuBarManager.shared.setPopoverHeight(_:)` which clamps and persists it.
    struct MenuBarPopoverResizeGrabber: View {
        @Environment(\.colorScheme) private var colorScheme
        @ObservedObject private var preferences = AppPreferences.shared
        @State private var dragStartHeight: CGFloat?
        @State private var isHovering: Bool = false
        @State private var cursorPushed: Bool = false

        private var colors: AppColorPalette {
            AppColors.palette(for: colorScheme)
        }

        private var isActive: Bool {
            isHovering || dragStartHeight != nil
        }

        var body: some View {
            ZStack {
                Capsule()
                    .fill(colors.textSecondary.opacity(isActive ? 0.42 : 0.22))
                    .frame(width: isActive ? 44 : 36, height: isActive ? 6 : 4)
                    .tlingoGlassCapsule(.chrome, interactive: true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .background(colors.cardBackground.opacity(isActive ? 0.10 : 0.04))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(colors.divider.opacity(isActive ? 0.8 : 0.45))
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.14), value: isActive)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeUpDown.push()
                    cursorPushed = true
                } else if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .onDisappear {
                // Hotkey-driven popover dismissal can remove this view while
                // the pointer is still over the grabber, so SwiftUI never
                // sends `onHover(false)`. Pop the cursor manually to avoid
                // leaving a stuck resize cursor on NSCursor's stack.
                if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start: CGFloat
                        if let existing = dragStartHeight {
                            start = existing
                        } else {
                            start = preferences.menuBarPopoverHeight
                            dragStartHeight = start
                        }
                        // Drag down → translation.height > 0 → grow popover.
                        // Skip the UserDefaults write per pixel; persist in onEnded.
                        MenuBarManager.shared.setPopoverHeight(start + value.translation.height, persist: false)
                    }
                    .onEnded { value in
                        if let start = dragStartHeight {
                            MenuBarManager.shared.setPopoverHeight(start + value.translation.height)
                        }
                        dragStartHeight = nil
                    }
            )
            .accessibilityLabel(Text("Resize popover"))
        }
    }

    /// Right-edge drag handle that lets the user widen the menu bar popover
    /// horizontally. Mirrors `MenuBarPopoverResizeGrabber` (vertical version)
    /// but tracks horizontal translation and forwards to
    /// `MenuBarManager.shared.setPopoverWidth(_:)`.
    struct MenuBarPopoverWidthResizeGrabber: View {
        @Environment(\.colorScheme) private var colorScheme
        @ObservedObject private var preferences = AppPreferences.shared
        @State private var dragStartWidth: CGFloat?
        @State private var isHovering: Bool = false
        @State private var cursorPushed: Bool = false

        private var colors: AppColorPalette {
            AppColors.palette(for: colorScheme)
        }

        private var isActive: Bool {
            isHovering || dragStartWidth != nil
        }

        var body: some View {
            ZStack {
                Capsule()
                    .fill(colors.textSecondary.opacity(isActive ? 0.42 : 0.22))
                    .frame(width: isActive ? 6 : 4, height: isActive ? 44 : 36)
                    .tlingoGlassCapsule(.chrome, interactive: true)
            }
            .frame(maxHeight: .infinity)
            .frame(width: 14)
            .background(colors.cardBackground.opacity(isActive ? 0.10 : 0.04))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(colors.divider.opacity(isActive ? 0.8 : 0.45))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.14), value: isActive)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
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
                        let start: CGFloat
                        if let existing = dragStartWidth {
                            start = existing
                        } else {
                            start = preferences.menuBarPopoverWidth
                            dragStartWidth = start
                        }
                        // Drag right → translation.width > 0 → widen popover.
                        MenuBarManager.shared.setPopoverWidth(start + value.translation.width, persist: false)
                    }
                    .onEnded { value in
                        if let start = dragStartWidth {
                            MenuBarManager.shared.setPopoverWidth(start + value.translation.width)
                        }
                        dragStartWidth = nil
                    }
            )
            .accessibilityLabel(Text("Resize popover width"))
        }
    }
#endif
