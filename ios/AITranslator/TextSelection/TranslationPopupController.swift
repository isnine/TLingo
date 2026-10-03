//
//  TranslationPopupController.swift
//  TLingo
//
//  Manages the lifecycle and positioning of the translation popup panel.
//

#if os(macOS)
    import AppKit
    import ShareCore
    import SwiftUI

    @MainActor
    final class TranslationPopupController: NSObject, NSWindowDelegate {
        var onDismiss: (() -> Void)?
        var onTranslationSucceeded: (() -> Void)?

        private var panel: TranslationPopupPanel?
        private var dismissMonitor: PopupDismissMonitor?
        private var currentViewModel: HomeViewModel?
        private var currentRequestID: UUID?

        #if DIRECT_DISTRIBUTION
            func showAtCursor(
                selection: SelectionTextGrabber.Selection,
                actionName: String? = nil,
                trialModels: [ModelConfig] = []
            ) {
                showAtCursor(
                    text: selection.text,
                    actionName: actionName,
                    trialModels: trialModels,
                    onReplace: { text in await selection.replace(with: text) }
                )
            }
        #endif

        func showAtCursor(
            text: String,
            near point: CGPoint? = nil,
            requestID: UUID? = nil,
            actionName: String? = nil,
            trialModels: [ModelConfig] = [],
            onReplace: ((String) async -> Bool)? = nil
        ) {
            dismiss()
            currentRequestID = requestID

            let viewModel = HomeViewModel(onboardingTrialModels: trialModels)
            currentViewModel = viewModel

            let initialSize = AppPreferences.shared.selectionPopupSize
            let newPanel = TranslationPopupPanel(contentRect: NSRect(origin: .zero, size: initialSize))

            let replace: ((String) -> Void)? = onReplace.map { operation in
                { [weak self, weak newPanel] text in
                    Task { @MainActor in
                        // Hide the key panel before Direct synthesizes a paste.
                        newPanel?.orderOut(nil)
                        guard await operation(text) else {
                            newPanel?.makeKeyAndOrderFront(nil)
                            return
                        }
                        self?.dismiss()
                    }
                }
            }
            let contentView = PopupTranslationView(
                viewModel: viewModel,
                onResizeDrag: { [weak self] delta in
                    self?.resizeBy(delta: delta)
                },
                onResizeEnded: { [weak self] in
                    self?.persistCurrentFrame()
                },
                onTranslationSucceeded: { [weak self] in
                    self?.onTranslationSucceeded?()
                },
                onReplace: replace
            )
            let hostingView = NSHostingView(rootView: contentView)
            hostingView.sizingOptions = []
            newPanel.contentView = hostingView

            // Position near cursor
            let requestedPoint = point ?? NSEvent.mouseLocation
            let cursorPos = NSScreen.screens.contains(where: { $0.frame.contains(requestedPoint) })
                ? requestedPoint : NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorPos) })
                ?? NSScreen.main
                ?? NSScreen.screens.first
            let savedOrigin = point == nil ? AppPreferences.shared.selectionPopupOrigin : nil
            let savedScreen = savedOrigin.flatMap { origin in
                NSScreen.screens.first(where: { $0.frame.contains(origin) })
            }

            if let savedOrigin, let savedScreen {
                let visibleFrame = savedScreen.visibleFrame
                let savedX = min(
                    max(savedOrigin.x, visibleFrame.minX + 8),
                    max(visibleFrame.minX + 8, visibleFrame.maxX - initialSize.width - 8)
                )
                let savedY = min(
                    max(savedOrigin.y, visibleFrame.minY + 8),
                    max(visibleFrame.minY + 8, visibleFrame.maxY - initialSize.height - 8)
                )
                newPanel.setFrame(
                    NSRect(x: savedX, y: savedY, width: initialSize.width, height: initialSize.height),
                    display: true
                )
            } else if let screen {
                let visibleFrame = screen.visibleFrame
                let offset: CGFloat = 20

                var originX = cursorPos.x + offset
                var originY = cursorPos.y - initialSize.height - offset

                // Clamp to screen bounds
                if originX + initialSize.width > visibleFrame.maxX {
                    originX = cursorPos.x - initialSize.width - offset
                }
                if originY < visibleFrame.minY {
                    originY = cursorPos.y + offset
                }
                if originX < visibleFrame.minX {
                    originX = visibleFrame.minX + 8
                }
                if originY + initialSize.height > visibleFrame.maxY {
                    originY = visibleFrame.maxY - initialSize.height - 8
                }

                newPanel.setFrame(
                    NSRect(x: originX, y: originY, width: initialSize.width, height: initialSize.height),
                    display: true
                )
            }

            newPanel.delegate = self
            panel = newPanel
            newPanel.orderFront(nil)
            startDismissMonitor()

            if HomeViewModel.isSnapshotMode {
                viewModel.inputText = text
                return
            }
            if let actionName {
                viewModel.applyDeepLink(text: text, actionName: actionName, configName: nil)
            } else {
                viewModel.inputText = text
                viewModel.performSelectedAction(
                    refreshEntitlement: false,
                    allowModelFallback: true
                )
            }
        }

        func dismiss() {
            dismissMonitor?.stop()
            dismissMonitor = nil
            persistCurrentFrame()
            panel?.contentView = nil
            panel?.close()
            panel = nil
            currentViewModel = nil
            currentRequestID = nil
            onDismiss?()
        }

        func dismiss(requestID: UUID) {
            guard currentRequestID == requestID else { return }
            dismiss()
        }

        var isVisible: Bool {
            panel?.isVisible ?? false
        }

        // MARK: - Resize

        /// Applies a cumulative drag delta from the bottom-right grabber.
        /// Anchored to the panel's top-left so the popup grows away from
        /// the cursor — matches macOS window resize convention and keeps
        /// the popup pinned near the originating text selection.
        func resizeBy(delta: CGSize) {
            guard let panel else { return }
            let current = panel.frame
            let target = CGSize(
                width: current.width + delta.width,
                height: current.height + delta.height
            )
            let clamped = clampToScreen(target, anchorTopLeft: current)
            guard abs(clamped.width - current.width) > 0.5 || abs(clamped.height - current.height) > 0.5 else { return }

            // AppKit origin is bottom-left; shift y so top edge stays put.
            let topLeftY = current.maxY
            let newFrame = NSRect(
                x: current.origin.x,
                y: topLeftY - clamped.height,
                width: clamped.width,
                height: clamped.height
            )
            panel.setFrame(newFrame, display: false)
        }

        private func persistCurrentFrame() {
            guard let panel else { return }
            AppPreferences.shared.setSelectionPopupSize(panel.frame.size)
            AppPreferences.shared.setSelectionPopupOrigin(panel.frame.origin)
        }

        /// Persisting on every move/resize event republished AppPreferences per drag frame;
        /// save once when the gesture ends and when the popup closes instead.
        func windowDidEndLiveResize(_: Notification) {
            persistCurrentFrame()
        }

        private func clampToScreen(_ size: CGSize, anchorTopLeft current: NSRect) -> CGSize {
            let screen = panel?.screen ?? NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? .zero
            let minSize = AppPreferences.selectionPopupMinSize
            let maxSize = AppPreferences.selectionPopupMaxSize
            let availableWidth = max(minSize.width, visible.maxX - current.origin.x - 8)
            let availableHeight = max(minSize.height, current.maxY - visible.minY - 8)
            let width = min(max(minSize.width, size.width), min(maxSize.width, availableWidth))
            let height = min(max(minSize.height, size.height), min(maxSize.height, availableHeight))
            return CGSize(width: width, height: height)
        }

        private func startDismissMonitor() {
            guard let panel else { return }
            dismissMonitor = PopupDismissMonitor(panel: panel) { [weak self] in
                self?.dismiss()
            }
            dismissMonitor?.start()
        }
    }
#endif
