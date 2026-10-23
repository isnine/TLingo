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

        func translate(text: String, near point: CGPoint? = nil, requestID: UUID? = nil, actionID: String? = nil) {
            popupController.showAtCursor(text: text, near: point, requestID: requestID, actionID: actionID)
        }

        func dismissPopup(requestID: UUID) {
            popupController.dismiss(requestID: requestID)
        }
    }
#endif
