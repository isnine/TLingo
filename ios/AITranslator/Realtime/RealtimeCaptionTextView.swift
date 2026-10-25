#if os(iOS)
    import os
    import ShareCore
    import SwiftUI
    import UIKit

    /// Live caption list backed by a single TextKit 1 `UITextView`.
    ///
    /// SwiftUI's lazy stacks estimate off-screen heights and `scrollTo` fights `defaultScrollAnchor`,
    /// which made captions jump hundreds of points per update. Here layout is computed eagerly,
    /// updates only rewrite the changed tail of the text storage, and the bottom pin is applied
    /// synchronously after each layout pass, so the visible text never leaves the viewport.
    struct RealtimeCaptionTextView: UIViewRepresentable {
        struct Style: Equatable {
            var sourceColor: UIColor
            var translationColor: UIColor
            var pendingColor: UIColor

            init(palette: AppColorPalette) {
                sourceColor = UIColor(palette.textSecondary)
                translationColor = UIColor(palette.textPrimary)
                pendingColor = UIColor(palette.accent)
            }
        }

        static let horizontalPadding: CGFloat = 22
        static let topPadding: CGFloat = 12
        static let bottomPadding: CGFloat = 16
        private static let lineGap: CGFloat = 18

        /// Caption text exactly as the in-app list lays it out; the Picture in Picture frame draws the same string.
        static func attributedText(for lines: [RealtimeCaptionLine], style: Style) -> NSAttributedString {
            let text = NSMutableAttributedString()
            for (index, line) in lines.enumerated() {
                let attributes = attributes(for: line, style: style)
                if index > 0 {
                    text.append(NSAttributedString(string: "\n", attributes: attributes))
                }
                text.append(NSAttributedString(string: line.text, attributes: attributes))
            }
            return text
        }

        static func attributes(for line: RealtimeCaptionLine, style: Style) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = line.kind == .source ? 3 : 6
            paragraph.paragraphSpacing = lineGap
            let color: UIColor = line.isPending
                ? style.pendingColor
                : (line.kind == .source ? style.sourceColor : style.translationColor)
            return [
                .font: font(for: line.kind),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        }

        private static let sourceFont = roundedFont(size: 17, weight: .medium)
        private static let translationFont = roundedFont(size: 24, weight: .semibold)

        private static func font(for kind: RealtimeCaptionLine.Kind) -> UIFont {
            kind == .source ? sourceFont : translationFont
        }

        private static func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
            return UIFont(descriptor: descriptor, size: size)
        }

        let lines: [RealtimeCaptionLine]
        let style: Style
        /// Height of the bottom accessory (control dock) that SwiftUI does not report as UIKit safe area.
        let bottomAccessoryHeight: CGFloat
        /// `RealtimeSessionStore.captionRevision` of `lines`; ties `[RT][view]` logs to `[RT][ui]`.
        let revision: Int

        func makeUIView(context _: Context) -> CaptionTextView {
            CaptionTextView()
        }

        func updateUIView(_ view: CaptionTextView, context _: Context) {
            view.update(lines: lines, style: style, bottomAccessoryHeight: bottomAccessoryHeight, revision: revision)
        }

        @MainActor
        final class CaptionTextView: UITextView, UITextViewDelegate {
            private static let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "Realtime")
            /// Distance from the bottom that still counts as "following" after the user scrolls.
            private static let followThreshold: CGFloat = 32
            /// Largest blank space kept under the last line when captions shrink, about one translation line plus a source line.
            private static let maxBottomSlack: CGFloat = 120

            private var renderedLines: [RealtimeCaptionLine] = []
            private var lineRanges: [NSRange] = []
            private var style: Style?
            private var bottomAccessoryHeight: CGFloat = 0
            private var isFollowingBottom = true
            private var revision = 0
            /// Blank space under the last line that absorbs a shrink (a long preview translation replaced by
            /// a shorter final one) so text above does not drop down; later growth consumes it first.
            private var bottomSlack: CGFloat = 0
            /// Layout state before the current `update` rewrote text storage. Replacing the tail lets
            /// UITextView clamp `contentOffset` against a stale content size before `applyLayout` runs.
            private var layoutBaseline: LayoutSnapshot?

            private struct LayoutSnapshot {
                var height: CGFloat
                var slack: CGFloat
                var offset: CGFloat
            }
            /// Lines rewritten by the last `update`; `-` when layout ran without a content change.
            private var lastReplaced = "-"

            init() {
                let storage = NSTextStorage()
                let layoutManager = NSLayoutManager()
                // Full contiguous layout keeps contentSize exact; estimated heights caused the jumps.
                layoutManager.allowsNonContiguousLayout = false
                storage.addLayoutManager(layoutManager)
                let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
                container.widthTracksTextView = true
                container.lineFragmentPadding = 0
                layoutManager.addTextContainer(container)
                super.init(frame: .zero, textContainer: container)

                isEditable = false
                isSelectable = true
                isScrollEnabled = true
                alwaysBounceVertical = true
                backgroundColor = .clear
                contentInsetAdjustmentBehavior = .never
                keyboardDismissMode = .interactive
                textContainerInset = UIEdgeInsets(
                    top: RealtimeCaptionTextView.topPadding,
                    left: RealtimeCaptionTextView.horizontalPadding,
                    bottom: RealtimeCaptionTextView.bottomPadding,
                    right: RealtimeCaptionTextView.horizontalPadding
                )
                topEdgeEffect.style = .soft
                bottomEdgeEffect.style = .soft
                delegate = self
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            func update(lines: [RealtimeCaptionLine], style: Style, bottomAccessoryHeight: CGFloat, revision: Int) {
                self.revision = revision
                let styleChanged = self.style != style
                self.style = style
                let insetsChanged = self.bottomAccessoryHeight != bottomAccessoryHeight
                self.bottomAccessoryHeight = bottomAccessoryHeight

                let previousCount = renderedLines.count
                lastReplaced = "-"
                layoutBaseline = LayoutSnapshot(height: laidOutContentHeight, slack: bottomSlack, offset: contentOffset.y)
                defer { layoutBaseline = nil }
                if styleChanged {
                    replaceLines(from: 0, with: lines)
                    lastReplaced = "0..<\(lines.count)/\(previousCount)"
                } else if let firstChange = firstChangedIndex(in: lines) {
                    replaceLines(from: firstChange, with: lines)
                    lastReplaced = "\(firstChange)..<\(lines.count)/\(previousCount)"
                } else if !insetsChanged {
                    return
                }
                if styleChanged || lines.isEmpty {
                    bottomSlack = 0
                }
                applyLayout(reason: styleChanged ? "style" : (insetsChanged ? "insets" : "content"))
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                if bounds.size != lastLayoutSize {
                    lastLayoutSize = bounds.size
                    applyLayout(reason: "bounds")
                } else if isFollowingBottom, !isTracking, !isDecelerating, bounds.height > 0, contentOffset.y != maxOffsetY {
                    // UITextView's own pass can clamp the offset against its lagging contentSize.
                    Self.logger.notice(
                        "[RT][view] rev=\(self.revision, privacy: .public) repin offset=\(Int(self.contentOffset.y), privacy: .public)->\(Int(self.maxOffsetY), privacy: .public) contentSize=\(Int(self.contentSize.height), privacy: .public)"
                    )
                    contentOffset = CGPoint(x: 0, y: maxOffsetY)
                }
            }

            private var lastLayoutSize: CGSize = .zero

            override func safeAreaInsetsDidChange() {
                super.safeAreaInsetsDidChange()
                applyLayout(reason: "safeArea")
            }

            /// Navigation bar and home indicator arrive as safe area; the dock is added on top of it.
            private var effectiveObscuredInsets: UIEdgeInsets {
                UIEdgeInsets(
                    top: safeAreaInsets.top,
                    left: 0,
                    bottom: safeAreaInsets.bottom + bottomAccessoryHeight,
                    right: 0
                )
            }

            // MARK: Text storage

            private func firstChangedIndex(in lines: [RealtimeCaptionLine]) -> Int? {
                let common = min(lines.count, renderedLines.count)
                for index in 0 ..< common where lines[index] != renderedLines[index] {
                    return index
                }
                return lines.count == renderedLines.count ? nil : common
            }

            /// Rewrites `lines[start...]`; lines before `start` keep their storage and layout.
            private func replaceLines(from start: Int, with lines: [RealtimeCaptionLine]) {
                guard let style else { return }
                let replaceLocation = start == 0 ? 0 : NSMaxRange(lineRanges[start - 1])
                let replaceRange = NSRange(location: replaceLocation, length: textStorage.length - replaceLocation)

                let tail = NSMutableAttributedString()
                var ranges = Array(lineRanges.prefix(start))
                var cursor = replaceLocation
                for index in start ..< lines.count {
                    if index > 0 {
                        tail.append(NSAttributedString(string: "\n", attributes: RealtimeCaptionTextView.attributes(for: lines[index], style: style)))
                        cursor += 1
                    }
                    let text = NSAttributedString(string: lines[index].text, attributes: RealtimeCaptionTextView.attributes(for: lines[index], style: style))
                    tail.append(text)
                    ranges.append(NSRange(location: cursor, length: text.length))
                    cursor += text.length
                }

                let selection = selectedRange
                textStorage.beginEditing()
                textStorage.replaceCharacters(in: replaceRange, with: tail)
                textStorage.endEditing()
                // Keep a selection that lies entirely in the untouched prefix.
                if selection.length > 0, NSMaxRange(selection) <= replaceLocation {
                    selectedRange = selection
                }

                renderedLines = lines
                lineRanges = ranges
            }

            // MARK: Scroll position

            private var contentHeight: CGFloat {
                layoutManager.ensureLayout(for: textContainer)
                let used = layoutManager.usedRect(for: textContainer).height
                return ceil(used + textContainerInset.top + textContainerInset.bottom)
            }

            /// Bottom-aligns short content through the top inset, then pins to the bottom if following.
            private func applyLayout(reason: String) {
                guard bounds.height > 0 else { return }
                let before = layoutBaseline ?? LayoutSnapshot(height: laidOutContentHeight, slack: bottomSlack, offset: contentOffset.y)
                let height = contentHeight
                laidOutContentHeight = height
                if reason == "content", isFollowingBottom, !isTracking, !isDecelerating {
                    bottomSlack = min(Self.maxBottomSlack, max(0, before.height + before.slack - height))
                }
                let obscured = effectiveObscuredInsets
                let viewport = bounds.height - obscured.top - obscured.bottom
                let alignmentGap = max(0, viewport - height - bottomSlack)
                let insets = UIEdgeInsets(
                    top: obscured.top + alignmentGap,
                    left: 0,
                    bottom: obscured.bottom + bottomSlack,
                    right: 0
                )
                if contentInset != insets {
                    contentInset = insets
                }
                verticalScrollIndicatorInsets = obscured

                if isFollowingBottom, !isTracking, !isDecelerating {
                    let target = CGPoint(x: 0, y: maxOffsetY)
                    if contentOffset != target {
                        contentOffset = target
                    }
                }
                logLayout(reason: reason, before: before)
            }

            /// Measured eagerly in `applyLayout`; `contentSize` lags until UITextView's next layout pass.
            private var laidOutContentHeight: CGFloat = 0

            private var maxOffsetY: CGFloat {
                max(-contentInset.top, laidOutContentHeight + contentInset.bottom - bounds.height)
            }

            private var distanceFromBottom: CGFloat {
                maxOffsetY - contentOffset.y
            }

            func scrollViewDidScroll(_ scrollView: UIScrollView) {
                guard scrollView.isTracking || scrollView.isDecelerating else { return }
                updateFollowing(trigger: "scroll")
            }

            func scrollViewDidEndDecelerating(_: UIScrollView) {
                updateFollowing(trigger: "decelerate")
            }

            func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
                if !decelerate {
                    updateFollowing(trigger: "drag")
                }
            }

            func scrollViewDidScrollToTop(_: UIScrollView) {
                updateFollowing(trigger: "scrollToTop")
            }

            private func updateFollowing(trigger: String) {
                let following = distanceFromBottom <= Self.followThreshold
                guard following != isFollowingBottom else { return }
                isFollowingBottom = following
                Self.logger.notice(
                    "[RT][scroll] following=\(following, privacy: .public) trigger=\(trigger, privacy: .public) fromBottom=\(Int(self.distanceFromBottom), privacy: .public)"
                )
            }

            /// One line per layout pass. `shift` is how far text above the edited line moved on screen
            /// (negative = up, positive = the downward jump a shrink causes); `slack` is blank space
            /// kept under the last line to absorb shrinks.
            private func logLayout(reason: String, before: LayoutSnapshot) {
                let heightDelta = laidOutContentHeight - before.height
                let offsetDelta = contentOffset.y - before.offset
                // Text above the edit keeps its content y, so its screen y moves by -(offset change).
                let shift = -offsetDelta
                let tailHeight = lineRanges.last.map {
                    layoutManager.boundingRect(
                        forGlyphRange: layoutManager.glyphRange(forCharacterRange: $0, actualCharacterRange: nil),
                        in: textContainer
                    ).height
                } ?? 0
                Self.logger.notice(
                    """
                    [RT][view] rev=\(self.revision, privacy: .public) reason=\(reason, privacy: .public) \
                    replaced=\(self.lastReplaced, privacy: .public) \
                    height=\(Int(before.height), privacy: .public)->\(Int(self.laidOutContentHeight), privacy: .public)(\(Int(heightDelta), privacy: .public)) \
                    offset=\(Int(before.offset), privacy: .public)->\(Int(self.contentOffset.y), privacy: .public)(\(Int(offsetDelta), privacy: .public)) \
                    insetTop=\(Int(self.contentInset.top), privacy: .public) \
                    slack=\(Int(before.slack), privacy: .public)->\(Int(self.bottomSlack), privacy: .public) \
                    shift=\(Int(shift), privacy: .public) tailH=\(Int(tailHeight), privacy: .public) \
                    viewport=\(Int(self.bounds.height), privacy: .public) dock=\(Int(self.bottomAccessoryHeight), privacy: .public) \
                    safeArea=\(Int(self.safeAreaInsets.top), privacy: .public)/\(Int(self.safeAreaInsets.bottom), privacy: .public) \
                    following=\(self.isFollowingBottom, privacy: .public) tracking=\(self.isTracking || self.isDecelerating, privacy: .public) \
                    lines=\(self.renderedLines.count, privacy: .public)
                    """
                )
                lastReplaced = "-"
            }
        }
    }
#endif
