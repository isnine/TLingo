import os
import SwiftUI

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "ImagePaste")
private let languageShortcutLogger = os.Logger(
    subsystem: "com.zanderwang.AITranslator",
    category: "LanguageShortcut"
)
#if canImport(AppKit)
    import AppKit
#endif
#if canImport(UIKit)
    import UIKit
#endif

#if os(macOS)
    struct AutoPasteTextEditor: NSViewRepresentable {
        @Binding var text: String
        let placeholder: String
        let onPaste: (String) -> Void
        var onImagePaste: (([NSImage]) -> Void)?
        var onContentHeightChange: ((CGFloat) -> Void)?
        var onSubmit: (() -> Void)?
        var onSwapLanguages: (() -> Void)?

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeNSView(context: Context) -> NSScrollView {
            let textView = PastingTextView()
            textView.delegate = context.coordinator
            textView.isRichText = false
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 16, height: 12)
            textView.textContainer?.lineFragmentPadding = 0
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.string = text
            textView.onPaste = onPaste
            textView.onImagePaste = onImagePaste
            textView.onSubmit = onSubmit
            textView.onSwapLanguages = onSwapLanguages
            textView.languageShortcutContext = "main"
            textView.placeholderAttributedString = makePlaceholderAttributedString()

            // Register for drag & drop of image files and image pasteboard types
            textView.registerForDraggedTypes([.fileURL, .tiff, .png, NSPasteboard.PasteboardType("public.jpeg")])

            // Store reference for the local event monitor in Coordinator
            context.coordinator.textView = textView

            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.contentView.drawsBackground = false
            scrollView.documentView = textView
            return scrollView
        }

        func updateNSView(_ nsView: NSScrollView, context: Context) {
            guard let textView = nsView.documentView as? PastingTextView else {
                return
            }

            context.coordinator.update(parent: self)

            if textView.string != text {
                textView.string = text
            }

            textView.onPaste = onPaste
            textView.onImagePaste = onImagePaste
            textView.onSubmit = onSubmit
            textView.onSwapLanguages = onSwapLanguages
            if textView.placeholderAttributedString?.string != placeholder {
                textView.placeholderAttributedString = makePlaceholderAttributedString()
            }
            context.coordinator.reportContentHeight(for: textView)
        }

        final class Coordinator: NSObject, NSTextViewDelegate {
            private var parent: AutoPasteTextEditor
            private var lastReportedContentHeight: CGFloat = 0
            private var eventMonitor: Any?
            weak var textView: PastingTextView?

            init(parent: AutoPasteTextEditor) {
                self.parent = parent
                super.init()
                // Install local event monitor to intercept Cmd+V before SwiftUI's
                // NSHostingView routes it to the auto-generated Edit > Paste menu item.
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let textView = self.textView else { return event }
                    if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                       event.charactersIgnoringModifiers == "v",
                       textView.window?.isKeyWindow == true,
                       textView.window?.firstResponder === textView
                    {
                        textView.paste(nil)
                        return nil // consume event
                    }
                    return event
                }
            }

            func update(parent: AutoPasteTextEditor) {
                self.parent = parent
            }

            deinit {
                if let monitor = eventMonitor {
                    NSEvent.removeMonitor(monitor)
                }
            }

            func textDidChange(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                let updated = textView.string
                if parent.text != updated {
                    parent.text = updated
                }
                reportContentHeight(for: textView)
            }

            func reportContentHeight(for textView: NSTextView) {
                guard let layoutManager = textView.layoutManager,
                      let textContainer = textView.textContainer
                else { return }

                layoutManager.ensureLayout(for: textContainer)
                let usedRect = layoutManager.usedRect(for: textContainer)
                let height = ceil(usedRect.height + textView.textContainerInset.height * 2)
                reportContentHeight(height)
            }

            private func reportContentHeight(_ height: CGFloat) {
                guard height.isFinite, abs(height - lastReportedContentHeight) > 0.5 else { return }
                lastReportedContentHeight = height
                DispatchQueue.main.async { [parent] in
                    parent.onContentHeightChange?(height)
                }
            }
        }

        private func makePlaceholderAttributedString() -> NSAttributedString {
            NSAttributedString(
                string: placeholder,
                attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        }
    }

    public class LanguageSwapTextView: NSTextView {
        public var onSwapLanguages: (() -> Void)?
        public var languageShortcutContext = "unknown"

        override public func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard event.keyCode == 48 else {
                super.keyDown(with: event)
                return
            }

            let markedText = hasMarkedText()
            let hasHandler = onSwapLanguages != nil
            let isFirstResponder = window?.firstResponder === self
            languageShortcutLogger.notice(
                "Tab keyDown context=\(self.languageShortcutContext, privacy: .public) modifiers=\(modifiers.rawValue, privacy: .public) markedText=\(markedText, privacy: .public) handler=\(hasHandler, privacy: .public) firstResponder=\(isFirstResponder, privacy: .public)"
            )
            guard modifiers.isEmpty, !markedText, let onSwapLanguages else {
                languageShortcutLogger.notice(
                    "Tab passed through context=\(self.languageShortcutContext, privacy: .public)"
                )
                super.keyDown(with: event)
                return
            }
            languageShortcutLogger.notice(
                "Tab consumed context=\(self.languageShortcutContext, privacy: .public)"
            )
            onSwapLanguages()
        }

        override public func doCommand(by selector: Selector) {
            guard selector == NSSelectorFromString("insertTab:") else {
                super.doCommand(by: selector)
                return
            }

            let markedText = hasMarkedText()
            let hasHandler = onSwapLanguages != nil
            languageShortcutLogger.notice(
                "insertTab command context=\(self.languageShortcutContext, privacy: .public) markedText=\(markedText, privacy: .public) handler=\(hasHandler, privacy: .public)"
            )
            guard !markedText, let onSwapLanguages else {
                super.doCommand(by: selector)
                return
            }
            languageShortcutLogger.notice(
                "insertTab consumed context=\(self.languageShortcutContext, privacy: .public)"
            )
            onSwapLanguages()
        }
    }

    final class PastingTextView: LanguageSwapTextView {
        var onPaste: ((String) -> Void)?
        var onImagePaste: (([NSImage]) -> Void)?
        var onSubmit: (() -> Void)?
        var placeholderAttributedString: NSAttributedString? {
            didSet { needsDisplay = true }
        }

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isReturnKey = event.keyCode == 36 || event.keyCode == 76
            if isReturnKey, flags == .command || flags == .shift {
                onSubmit?()
                return
            }
            super.keyDown(with: event)
        }

        override func paste(_ sender: Any?) {
            // Only handle image paste when this text view has focus.
            // When both the popover and main window are visible, this prevents
            // images from appearing in the wrong input field.
            guard window?.firstResponder === self else {
                super.paste(sender)
                return
            }

            let pb = NSPasteboard.general

            if let image = pb.imageFromData() {
                logger.debug("Paste: image from raw data, size: \(image.size.debugDescription, privacy: .public)")
                onImagePaste?([image])
                return
            }

            let images = pb.imagesFromFileURLs()
            if !images.isEmpty {
                logger.debug("Paste: \(images.count, privacy: .public) image(s) from file URLs")
                onImagePaste?(images)
                return
            }

            // Fall through to text paste
            super.paste(sender)
            let current = string
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onPaste?(current)
            needsDisplay = true
        }

        // MARK: - Drag & Drop

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            if sender.draggingPasteboard.containsImage {
                return .copy
            }
            return super.draggingEntered(sender)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard

            let images = pb.imagesFromFileURLs()
            if !images.isEmpty {
                onImagePaste?(images)
                return true
            }

            if let image = pb.imageFromData() {
                onImagePaste?([image])
                return true
            }

            return super.performDragOperation(sender)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty,
                  window?.firstResponder !== self,
                  let placeholder = placeholderAttributedString
            else {
                return
            }

            let inset = textContainerInset
            let padding = textContainer?.lineFragmentPadding ?? 0
            // Draw placeholder at top-left (text cursor position), not vertically centered
            let origin = CGPoint(
                x: inset.width + padding,
                y: inset.height
            )
            placeholder.draw(at: origin)
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { needsDisplay = true }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result { needsDisplay = true }
            return result
        }

        override func didChangeText() {
            super.didChangeText()
            needsDisplay = true
        }
    }

#elseif os(iOS)
    struct AutoPasteTextEditor: UIViewRepresentable {
        @Binding var text: String
        let placeholder: String
        let onPaste: (String) -> Void
        var onImagePaste: (([UIImage]) -> Void)?
        var onContentHeightChange: ((CGFloat) -> Void)?
        var onSubmit: (() -> Void)?
        var autoFocus = false
        var onSwapLanguages: (() -> Void)?

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeUIView(context: Context) -> PastingTextView {
            let textView = PastingTextView()
            textView.delegate = context.coordinator
            textView.backgroundColor = .clear
            textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
            textView.text = text
            textView.onPaste = onPaste
            textView.onImagePaste = onImagePaste
            textView.onSubmit = onSubmit
            textView.onSwapLanguages = onSwapLanguages
            textView.languageShortcutContext = "main"
            textView.isScrollEnabled = true
            textView.alwaysBounceVertical = true
            textView.adjustsFontForContentSizeCategory = true
            textView.font = UIFont.preferredFont(forTextStyle: .body)
            textView.autocorrectionType = .default
            textView.smartDashesType = .no
            textView.smartQuotesType = .no
            textView.accessibilityHint = placeholder
            if autoFocus {
                DispatchQueue.main.async {
                    textView.becomeFirstResponder()
                }
            }
            return textView
        }

        func updateUIView(_ uiView: PastingTextView, context: Context) {
            context.coordinator.update(parent: self)
            if uiView.text != text {
                uiView.text = text
            }
            uiView.onPaste = onPaste
            uiView.onImagePaste = onImagePaste
            uiView.onSubmit = onSubmit
            uiView.onSwapLanguages = onSwapLanguages
            context.coordinator.reportContentHeight(for: uiView)
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            private var parent: AutoPasteTextEditor
            private var lastReportedContentHeight: CGFloat = 0

            init(parent: AutoPasteTextEditor) {
                self.parent = parent
            }

            func update(parent: AutoPasteTextEditor) {
                self.parent = parent
            }

            func textViewDidChange(_ textView: UITextView) {
                let updated = textView.text ?? ""
                if parent.text != updated {
                    parent.text = updated
                }
                reportContentHeight(for: textView)
            }

            func reportContentHeight(for textView: UITextView) {
                guard textView.bounds.width > 0 else { return }
                let fittingSize = textView.sizeThatFits(
                    CGSize(width: textView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
                )
                reportContentHeight(ceil(fittingSize.height))
            }

            private func reportContentHeight(_ height: CGFloat) {
                guard height.isFinite, abs(height - lastReportedContentHeight) > 0.5 else { return }
                lastReportedContentHeight = height
                DispatchQueue.main.async { [parent] in
                    parent.onContentHeightChange?(height)
                }
            }
        }
    }

    final class PastingTextView: UITextView {
        var onPaste: ((String) -> Void)?
        var onImagePaste: (([UIImage]) -> Void)?
        var onSubmit: (() -> Void)?
        var onSwapLanguages: (() -> Void)?
        var languageShortcutContext = "unknown"

        override var keyCommands: [UIKeyCommand]? {
            var commands = [
                UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(submit)),
                UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(submit)),
            ]
            if onSwapLanguages != nil, markedTextRange == nil {
                let swap = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(swapLanguages))
                swap.wantsPriorityOverSystemBehavior = true
                commands.append(swap)
            }
            return commands
        }

        @objc private func swapLanguages() {
            languageShortcutLogger.notice(
                "Tab command context=\(self.languageShortcutContext, privacy: .public) markedText=\(self.markedTextRange != nil, privacy: .public) handler=\(self.onSwapLanguages != nil, privacy: .public) firstResponder=\(self.isFirstResponder, privacy: .public)"
            )
            guard markedTextRange == nil, let onSwapLanguages else { return }
            languageShortcutLogger.notice(
                "Tab consumed context=\(self.languageShortcutContext, privacy: .public)"
            )
            onSwapLanguages()
        }

        @objc private func submit() {
            onSubmit?()
        }

        override func paste(_ sender: Any?) {
            // Check for images on the pasteboard first
            let pb = UIPasteboard.general
            if pb.hasImages, let images = pb.images, !images.isEmpty {
                onImagePaste?(images)
                return
            }

            // Fall through to text paste
            super.paste(sender)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let current = self.text ?? ""
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self.onPaste?(current)
            }
        }
    }
#endif
