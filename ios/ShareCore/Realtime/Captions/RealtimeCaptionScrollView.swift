#if os(macOS)
    import AppKit
    import SwiftUI

    /// Live caption list backed by a single TextKit 1 `NSTextView`.
    ///
    /// Mirrors the iOS `RealtimeCaptionTextView`: SwiftUI lazy stacks estimate row heights and
    /// `scrollTo` fights `defaultScrollAnchor`, which made captions jump. Here layout is computed
    /// eagerly, updates only rewrite the changed tail, and the bottom pin is applied synchronously
    /// unless the user has scrolled away from the bottom.
    public struct RealtimeCaptionScrollView: NSViewRepresentable {
        public struct Style: Equatable {
            public var sourceFont: NSFont
            public var translationFont: NSFont
            public var sourceColor: NSColor
            public var translationColor: NSColor
            public var pendingColor: NSColor
            public var sourceLineSpacing: CGFloat
            public var translationLineSpacing: CGFloat
            public var lineGap: CGFloat
            public var horizontalPadding: CGFloat
            public var verticalPadding: CGFloat
            /// Short content sits at the bottom of the viewport instead of the top.
            public var alignsShortContentToBottom: Bool
            /// When false, mouse drags move the window instead of selecting text.
            public var isSelectable: Bool

            public init(
                sourceFont: NSFont,
                translationFont: NSFont,
                sourceColor: NSColor,
                translationColor: NSColor,
                pendingColor: NSColor,
                sourceLineSpacing: CGFloat,
                translationLineSpacing: CGFloat,
                lineGap: CGFloat,
                horizontalPadding: CGFloat,
                verticalPadding: CGFloat,
                alignsShortContentToBottom: Bool,
                isSelectable: Bool
            ) {
                self.sourceFont = sourceFont
                self.translationFont = translationFont
                self.sourceColor = sourceColor
                self.translationColor = translationColor
                self.pendingColor = pendingColor
                self.sourceLineSpacing = sourceLineSpacing
                self.translationLineSpacing = translationLineSpacing
                self.lineGap = lineGap
                self.horizontalPadding = horizontalPadding
                self.verticalPadding = verticalPadding
                self.alignsShortContentToBottom = alignsShortContentToBottom
                self.isSelectable = isSelectable
            }

            public static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
                let base = NSFont.systemFont(ofSize: size, weight: weight)
                guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
                return NSFont(descriptor: descriptor, size: size) ?? base
            }
        }

        let lines: [RealtimeCaptionLine]
        let style: Style

        public init(lines: [RealtimeCaptionLine], style: Style) {
            self.lines = lines
            self.style = style
        }

        public func makeNSView(context _: Context) -> CaptionScrollView {
            CaptionScrollView()
        }

        public func updateNSView(_ view: CaptionScrollView, context _: Context) {
            view.update(lines: lines, style: style)
        }

        @MainActor
        public final class CaptionScrollView: NSScrollView {
            /// Distance from the bottom that still counts as "following" after the user scrolls.
            private static let followThreshold: CGFloat = 32

            private let textView: CaptionTextView
            private var renderedLines: [RealtimeCaptionLine] = []
            private var lineRanges: [NSRange] = []
            private var style: Style?
            private var isFollowingBottom = true
            private var laidOutContentHeight: CGFloat = 0
            private var lastLayoutSize: NSSize = .zero

            init() {
                let storage = NSTextStorage()
                let layoutManager = NSLayoutManager()
                // Full contiguous layout keeps the measured height exact.
                layoutManager.allowsNonContiguousLayout = false
                storage.addLayoutManager(layoutManager)
                let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
                container.widthTracksTextView = true
                container.lineFragmentPadding = 0
                layoutManager.addTextContainer(container)
                textView = CaptionTextView(frame: .zero, textContainer: container)
                super.init(frame: .zero)

                textView.isEditable = false
                textView.isRichText = false
                textView.drawsBackground = false
                textView.isVerticallyResizable = true
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [.width]
                textView.minSize = .zero
                textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

                drawsBackground = false
                contentView.drawsBackground = false
                hasVerticalScroller = true
                hasHorizontalScroller = false
                autohidesScrollers = true
                automaticallyAdjustsContentInsets = false
                documentView = textView

                let center = NotificationCenter.default
                center.addObserver(self, selector: #selector(userWillLiveScroll), name: NSScrollView.willStartLiveScrollNotification, object: self)
                center.addObserver(self, selector: #selector(userDidLiveScroll), name: NSScrollView.didLiveScrollNotification, object: self)
                center.addObserver(self, selector: #selector(userDidEndLiveScroll), name: NSScrollView.didEndLiveScrollNotification, object: self)
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            func update(lines: [RealtimeCaptionLine], style: Style) {
                let styleChanged = self.style != style
                self.style = style
                if styleChanged {
                    textView.isSelectable = style.isSelectable
                    textView.textContainerInset = NSSize(width: style.horizontalPadding, height: style.verticalPadding)
                    replaceLines(from: 0, with: lines)
                } else if let firstChange = firstChangedIndex(in: lines) {
                    replaceLines(from: firstChange, with: lines)
                } else {
                    return
                }
                applyLayout()
            }

            override public func layout() {
                super.layout()
                if bounds.size != lastLayoutSize {
                    lastLayoutSize = bounds.size
                    applyLayout()
                }
            }

            override public func scrollWheel(with event: NSEvent) {
                super.scrollWheel(with: event)
                updateFollowing(trigger: "wheel")
            }

            @objc private func userWillLiveScroll() {
                isUserScrolling = true
            }

            @objc private func userDidLiveScroll() {
                updateFollowing(trigger: "live")
            }

            @objc private func userDidEndLiveScroll() {
                isUserScrolling = false
                updateFollowing(trigger: "liveEnd")
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
                guard let style, let storage = textView.textStorage else { return }
                let replaceLocation = start == 0 ? 0 : NSMaxRange(lineRanges[start - 1])
                let replaceRange = NSRange(location: replaceLocation, length: storage.length - replaceLocation)

                let tail = NSMutableAttributedString()
                var ranges = Array(lineRanges.prefix(start))
                var cursor = replaceLocation
                for index in start ..< lines.count {
                    let attributes = Self.attributes(for: lines[index], style: style)
                    if index > 0 {
                        tail.append(NSAttributedString(string: "\n", attributes: attributes))
                        cursor += 1
                    }
                    let text = NSAttributedString(string: lines[index].text, attributes: attributes)
                    tail.append(text)
                    ranges.append(NSRange(location: cursor, length: text.length))
                    cursor += text.length
                }

                let selection = textView.selectedRange()
                storage.beginEditing()
                storage.replaceCharacters(in: replaceRange, with: tail)
                storage.endEditing()
                // Keep a selection that lies entirely in the untouched prefix.
                if selection.length > 0, NSMaxRange(selection) <= replaceLocation {
                    textView.setSelectedRange(selection)
                }

                renderedLines = lines
                lineRanges = ranges
            }

            private static func attributes(for line: RealtimeCaptionLine, style: Style) -> [NSAttributedString.Key: Any] {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = line.kind == .source ? style.sourceLineSpacing : style.translationLineSpacing
                paragraph.paragraphSpacing = style.lineGap
                let color: NSColor = line.isPending
                    ? style.pendingColor
                    : (line.kind == .source ? style.sourceColor : style.translationColor)
                return [
                    .font: line.kind == .source ? style.sourceFont : style.translationFont,
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                ]
            }

            // MARK: Scroll position

            /// Sizes the document to its text, aligns short content, then pins to the bottom if following.
            private func applyLayout() {
                let viewport = contentView.bounds.height
                guard viewport > 0, let layoutManager = textView.layoutManager,
                      let container = textView.textContainer, let style else { return }

                let width = contentView.bounds.width
                if textView.frame.width != width {
                    textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
                }
                layoutManager.ensureLayout(for: container)
                let used = layoutManager.usedRect(for: container).height
                let height = ceil(used + textView.textContainerInset.height * 2)
                laidOutContentHeight = height
                if textView.frame.height != height {
                    textView.setFrameSize(NSSize(width: width, height: height))
                }

                let gap = style.alignsShortContentToBottom ? max(0, viewport - height) : 0
                if contentInsets.top != gap {
                    contentInsets = NSEdgeInsets(top: gap, left: 0, bottom: 0, right: 0)
                }

                if isFollowingBottom, !isUserScrolling {
                    let target = NSPoint(x: 0, y: maxOffsetY)
                    if contentView.bounds.origin != target {
                        contentView.scroll(to: target)
                        reflectScrolledClipView(contentView)
                    }
                }
            }

            /// Set between the live-scroll notifications so content updates do not yank a scroll in progress.
            private var isUserScrolling = false

            private var maxOffsetY: CGFloat {
                max(-contentInsets.top, laidOutContentHeight + contentInsets.bottom - contentView.bounds.height)
            }

            private func updateFollowing(trigger: String) {
                let distance = maxOffsetY - contentView.bounds.origin.y
                let following = distance <= Self.followThreshold
                guard following != isFollowingBottom else { return }
                isFollowingBottom = following
                RealtimeLog.log("scroll", "following=\(following) trigger=\(trigger) fromBottom=\(Int(distance))")
            }
        }

        final class CaptionTextView: NSTextView {
            override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
                true
            }

            override func mouseDown(with event: NSEvent) {
                // Non-selectable captions sit in a draggable caption window.
                guard isSelectable else {
                    window?.performDrag(with: event)
                    return
                }
                super.mouseDown(with: event)
            }
        }
    }
#endif
