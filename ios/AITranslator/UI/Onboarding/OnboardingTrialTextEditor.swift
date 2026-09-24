//
//  OnboardingTrialTextEditor.swift
//  TLingo
//
//  Created by AI Assistant on 2026/06/11.
//

#if os(iOS) && !targetEnvironment(macCatalyst)
    import SwiftUI
    import UIKit

    /// A `UITextView` wrapper that:
    ///   * Suppresses the system "Translate" entry in the edit menu
    ///     (selector `_translate:`), so the user can't escape the onboarding
    ///     flow into Apple's system translator while we're showcasing our
    ///     own premium models.
    ///   * Injects a "Translate with TLingo" action into the edit menu that
    ///     fires the same callback as the page-level primary button.
    ///
    /// Intentionally narrow-scoped to the onboarding trial step — do not
    /// drop this into HomeView or any reusable editor surface.
    struct OnboardingTrialTextEditor: UIViewRepresentable {
        @Binding var text: String
        var font: UIFont = .preferredFont(forTextStyle: .body)
        var customActionTitle: String
        var onCustomAction: (String) -> Void
        var onFeedback: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeUIView(context: Context) -> UITextView {
            let textView = OnboardingTrialUITextView()
            textView.delegate = context.coordinator
            textView.font = font
            textView.backgroundColor = .clear
            textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
            textView.adjustsFontForContentSizeCategory = true
            textView.isScrollEnabled = false
            textView.alwaysBounceVertical = false
            textView.text = text
            textView.menuConfigurator = context.coordinator
            return textView
        }

        func updateUIView(_ uiView: UITextView, context: Context) {
            if uiView.text != text {
                uiView.text = text
            }
            context.coordinator.parent = self
        }

        final class Coordinator: NSObject, UITextViewDelegate, OnboardingTrialMenuConfiguring {
            var parent: OnboardingTrialTextEditor

            init(_ parent: OnboardingTrialTextEditor) {
                self.parent = parent
            }

            func textViewDidChange(_ textView: UITextView) {
                parent.text = textView.text
            }

            // MARK: - Menu configuration

            func customActionTitle() -> String {
                parent.customActionTitle
            }

            func performCustomAction(actionText: String) {
                parent.onCustomAction(actionText)
            }

            func performFeedback() {
                parent.onFeedback()
            }
        }
    }

    private protocol OnboardingTrialMenuConfiguring: AnyObject {
        func customActionTitle() -> String
        func performCustomAction(actionText: String)
        func performFeedback()
    }

    private final class OnboardingTrialUITextView: UITextView {
        weak var menuConfigurator: OnboardingTrialMenuConfiguring?

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            // Let the SwiftUI parent dictate the width; without this UITextView
            // reports an unbounded intrinsic horizontal size whenever a single
            // word/line is wider than the visible frame, causing the whole view
            // to overflow the screen.
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var intrinsicContentSize: CGSize {
            // Width: leave it to the parent. Height: report the size needed to
            // fit the text at the current width so SwiftUI grows the view
            // vertically as the user types.
            guard bounds.width > 0 else {
                return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
            }
            let fitting = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
            return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fitting.height))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Force the text container to wrap at the current frame width.
            // Without this, a paste of one long line stays on one line and the
            // text view tries to grow horizontally.
            let horizontalInset = textContainerInset.left + textContainerInset.right
            let targetWidth = max(0, bounds.width - horizontalInset)
            if textContainer.size.width != targetWidth {
                textContainer.size = CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
                invalidateIntrinsicContentSize()
            }
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            // The system Translation action is exposed as `_translate:`.
            // Returning false here removes it from the standard edit menu and
            // from the long-press loupe menu.
            if action == Selector(("_translate:")) {
                return false
            }
            return super.canPerformAction(action, withSender: sender)
        }

        override func buildMenu(with builder: any UIMenuBuilder) {
            super.buildMenu(with: builder)

            guard let configurator = menuConfigurator else { return }

            let title = configurator.customActionTitle()
            let actionText = menuActionText
            let action = UIAction(
                title: title,
                image: UIImage(systemName: "character.bubble")
            ) { [weak self] _ in
                guard self != nil else { return }
                configurator.performCustomAction(actionText: actionText)
            }
            let feedbackAction = UIAction(
                title: String(localized: "Feedback"),
                image: UIImage(systemName: "envelope")
            ) { _ in
                configurator.performFeedback()
            }

            let menu = UIMenu(
                title: "",
                options: .displayInline,
                children: [action, feedbackAction]
            )

            // `.standardEdit` already contains Copy/Paste/Select; placing the
            // custom action ahead of it surfaces "Translate" as the first
            // entry, mirroring where iOS normally lists its Translate item.
            builder.insertSibling(menu, beforeMenu: .standardEdit)
        }

        private var menuActionText: String {
            let fullText = text ?? ""
            guard selectedRange.location != NSNotFound,
                  selectedRange.length > 0,
                  let range = Range(selectedRange, in: fullText)
            else {
                return fullText
            }
            return String(fullText[range])
        }
    }
#endif
