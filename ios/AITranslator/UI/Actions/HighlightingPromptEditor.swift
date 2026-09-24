//
//  HighlightingPromptEditor.swift
//  TLingo
//
//  A multi-line text editor that live-highlights prompt placeholder tokens
//  ({text}, {sourceLanguage}, {targetLanguage} and their {{...}} variants).
//

import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif
#if canImport(UIKit)
    import UIKit
#endif

/// Matches the supported placeholder tokens, preferring the double-brace form.
/// Mirrors the tokens handled in `PromptSubstitution`.
private let placeholderRegex: NSRegularExpression = {
    do {
        return try NSRegularExpression(
            pattern: #"\{\{(?:text|sourceLanguage|targetLanguage)\}\}|\{(?:text|sourceLanguage|targetLanguage)\}"#
        )
    } catch {
        preconditionFailure("Invalid placeholder regex: \(error)")
    }
}()

#if os(macOS)
    typealias PlatformFont = NSFont
    typealias PlatformColor = NSColor
#else
    typealias PlatformFont = UIFont
    typealias PlatformColor = UIColor
#endif

/// Applies base styling to the whole string, then highlights every placeholder range.
private func applyHighlighting(
    to storage: NSTextStorage,
    fontSize: CGFloat,
    textColor: PlatformColor,
    highlightColor: PlatformColor
) {
    let fullRange = NSRange(location: 0, length: storage.length)
    let baseFont = PlatformFont.systemFont(ofSize: fontSize)
    let highlightFont = PlatformFont.systemFont(ofSize: fontSize, weight: .semibold)

    storage.beginEditing()
    storage.setAttributes([.font: baseFont, .foregroundColor: textColor], range: fullRange)
    for match in placeholderRegex.matches(in: storage.string, range: fullRange) {
        storage.addAttributes([.font: highlightFont, .foregroundColor: highlightColor], range: match.range)
    }
    storage.endEditing()
}

#if os(macOS)
    struct HighlightingPromptEditor: NSViewRepresentable {
        @Binding var text: String
        var fontSize: CGFloat = 15
        var textColor: Color
        var highlightColor: Color
        var isEditable: Bool = true

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeNSView(context: Context) -> NSScrollView {
            let textView = NSTextView()
            textView.delegate = context.coordinator
            textView.isRichText = false
            textView.drawsBackground = false
            textView.isEditable = isEditable
            textView.textContainerInset = NSSize(width: 0, height: 0)
            textView.textContainer?.lineFragmentPadding = 0
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.string = text
            context.coordinator.applyHighlight(textView)

            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.contentView.drawsBackground = false
            scrollView.documentView = textView
            return scrollView
        }

        func updateNSView(_ nsView: NSScrollView, context: Context) {
            guard let textView = nsView.documentView as? NSTextView else { return }
            textView.isEditable = isEditable
            if textView.string != text {
                textView.string = text
                context.coordinator.applyHighlight(textView)
            }
        }

        final class Coordinator: NSObject, NSTextViewDelegate {
            private let parent: HighlightingPromptEditor

            init(parent: HighlightingPromptEditor) {
                self.parent = parent
            }

            func applyHighlight(_ textView: NSTextView) {
                guard let storage = textView.textStorage else { return }
                applyHighlighting(
                    to: storage,
                    fontSize: parent.fontSize,
                    textColor: NSColor(parent.textColor),
                    highlightColor: NSColor(parent.highlightColor)
                )
                textView.typingAttributes = [
                    .font: NSFont.systemFont(ofSize: parent.fontSize),
                    .foregroundColor: NSColor(parent.textColor),
                ]
            }

            func textDidChange(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                if parent.text != textView.string {
                    parent.text = textView.string
                }
                applyHighlight(textView)
            }
        }
    }

#else
    struct HighlightingPromptEditor: UIViewRepresentable {
        @Binding var text: String
        var fontSize: CGFloat = 15
        var textColor: Color
        var highlightColor: Color
        var isEditable: Bool = true

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeUIView(context: Context) -> UITextView {
            let textView = UITextView()
            textView.delegate = context.coordinator
            textView.backgroundColor = .clear
            textView.isEditable = isEditable
            textView.isScrollEnabled = false
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            textView.smartDashesType = .no
            textView.smartQuotesType = .no
            textView.text = text
            context.coordinator.applyHighlight(textView)
            return textView
        }

        func updateUIView(_ uiView: UITextView, context: Context) {
            uiView.isEditable = isEditable
            if uiView.text != text {
                uiView.text = text
                context.coordinator.applyHighlight(uiView)
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
            guard let width = proposal.width else { return nil }
            return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            private let parent: HighlightingPromptEditor

            init(parent: HighlightingPromptEditor) {
                self.parent = parent
            }

            func applyHighlight(_ textView: UITextView) {
                let selection = textView.selectedRange
                applyHighlighting(
                    to: textView.textStorage,
                    fontSize: parent.fontSize,
                    textColor: UIColor(parent.textColor),
                    highlightColor: UIColor(parent.highlightColor)
                )
                textView.selectedRange = selection
                textView.typingAttributes = [
                    .font: UIFont.systemFont(ofSize: parent.fontSize),
                    .foregroundColor: UIColor(parent.textColor),
                ]
            }

            func textViewDidChange(_ textView: UITextView) {
                let updated = textView.text ?? ""
                if parent.text != updated {
                    parent.text = updated
                }
                applyHighlight(textView)
            }
        }
    }
#endif
