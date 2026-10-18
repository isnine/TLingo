//
//  SelectionTranslationCoordinator.swift
//  TLingo
//
//  Top-level coordinator wiring: SelectionMonitor → TriggerIcon → TranslationPopup.
//

#if os(macOS)
    import AppKit
    import os
    import ShareCore

    private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "SelectionTranslation")

    @MainActor
    final class SelectionTranslationCoordinator {
        private let popupController = TranslationPopupController()
        #if DIRECT_DISTRIBUTION
            private let selectionMonitor = SelectionMonitor()
            private let triggerIconController = TriggerIconController()

            private var isRunning = false

            func start() {
                guard !isRunning else { return }
                isRunning = true
                logger.info("Text selection translation started")

                selectionMonitor.onTextSelected = { [weak self] point in
                    self?.triggerIconController.show(near: point)
                }

                selectionMonitor.onMouseDown = { [weak self] _ in
                    guard let self else { return }
                    if self.triggerIconController.isVisible {
                        self.triggerIconController.dismissSilently()
                    }
                    if self.popupController.isVisible {
                        self.popupController.dismiss()
                        self.selectionMonitor.suppressBriefly()
                    }
                }

                triggerIconController.onTranslateRequested = { [weak self] selection, _ in
                    guard let self else { return }
                    self.popupController.showAtCursor(selection: selection)
                }

                triggerIconController.onDismissed = { [weak self] in
                    self?.selectionMonitor.suppressBriefly()
                }

                popupController.onDismiss = { [weak self] in
                    self?.selectionMonitor.suppressBriefly()
                }

                selectionMonitor.start()
            }

            func stop() {
                guard isRunning else { return }
                isRunning = false
                logger.info("Text selection translation stopped")

                selectionMonitor.stop()
                triggerIconController.dismissSilently()
                if popupController.isVisible {
                    popupController.dismiss()
                }
            }

            func translateCurrentSelection() {
                Task { @MainActor in
                    guard let selection = await SelectionTextGrabber.grab(near: nil) else { return }
                    popupController.showAtCursor(selection: selection)
                }
            }
        #endif

        func translate(text: String, near point: CGPoint? = nil, requestID: UUID? = nil, actionID: String? = nil) {
            popupController.showAtCursor(text: text, near: point, requestID: requestID, actionID: actionID)
        }

        func dismissPopup(requestID: UUID) {
            popupController.dismiss(requestID: requestID)
        }
    }
#endif
