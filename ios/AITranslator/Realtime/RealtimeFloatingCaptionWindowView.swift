#if os(macOS)
    import AppKit
    import ShareCore
    import SwiftUI

    struct RealtimeFloatingCaptionWindowView: View {
        private static let contentHorizontalMargin: CGFloat = 20
        private static let contentVerticalMargin: CGFloat = 14
        private static let scrollIndicatorTrailingMargin: CGFloat = 8

        @ObservedObject private var preferences = AppPreferences.shared
        @ObservedObject var store: RealtimeSessionStore
        @State private var isHoveringCaptionWindow = false
        @State private var scrollContentHeight: CGFloat = 0
        @State private var scrollViewportHeight: CGFloat = 0
        @State private var captionClearAnchor = RealtimeCaptionDisplayClearAnchor.empty
        @State private var targetScreenHasBuiltInNotch = false

        private var resolvedCaptionLines: [RealtimeCaptionLine] {
            store.captionLines
        }

        private var captionLines: [RealtimeCaptionLine] {
            RealtimeCaptionDisplay.linesVisibleAfterClear(
                resolvedCaptionLines,
                anchor: captionClearAnchor
            )
        }

        private var shouldShowCaptionPlaceholder: Bool {
            captionLines.isEmpty && captionClearAnchor.isEmpty
        }

        private var captionWindowMode: RealtimeCaptionWindowMode {
            preferences.realtimeCaptionWindowMode
        }

        private var notchSize: CGSize {
            RealtimeNotchCaptionLayout.size(isCompact: !store.isRunning || store.isPaused)
        }

        var body: some View {
            Group {
                switch captionWindowMode {
                case .floating:
                    floatingCaptionBody
                case .notch:
                    notchCaptionBody
                }
            }
            .background(
                RealtimeFloatingWindowConfigurator(
                    mode: captionWindowMode,
                    privacyModeEnabled: preferences.realtimeCaptionPrivacyModeEnabled,
                    notchSize: notchSize,
                    targetScreenHasBuiltInNotch: $targetScreenHasBuiltInNotch
                )
            )
            .onChange(of: resolvedCaptionLines) {
                if resolvedCaptionLines.isEmpty {
                    captionClearAnchor = .empty
                }
            }
        }

        private var floatingCaptionBody: some View {
            captionPanel
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .frame(
                    minWidth: 420,
                    idealWidth: 760,
                    maxWidth: .infinity,
                    minHeight: 90,
                    idealHeight: 150,
                    maxHeight: .infinity
                )
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
                .overlay {
                    RealtimeFloatingCaptionDragSurface()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay(alignment: .topTrailing) {
                    captionControls
                        .opacity(isHoveringCaptionWindow ? 1 : 0)
                        .allowsHitTesting(isHoveringCaptionWindow)
                        .accessibilityHidden(!isHoveringCaptionWindow)
                        .padding(.top, 24)
                        .padding(.trailing, 28)
                }
                .overlay(alignment: .topLeading) {
                    closeCaptionButton
                        .opacity(isHoveringCaptionWindow ? 1 : 0)
                        .allowsHitTesting(isHoveringCaptionWindow)
                        .accessibilityHidden(!isHoveringCaptionWindow)
                        .padding(.top, 24)
                        .padding(.leading, 28)
                }
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isHoveringCaptionWindow = hovering
                    }
                }
        }

        private var notchCaptionBody: some View {
            RealtimeNotchCaptionWindowContent(
                store: store,
                captionLines: captionLines,
                captionDisplayModeButtonTitle: captionDisplayModeButtonTitle,
                targetScreenHasBuiltInNotch: targetScreenHasBuiltInNotch,
                onToggleRecognition: toggleRecognition,
                onEndRecognition: endRecognition,
                onClearCaptions: clearVisibleCaptions,
                onClose: closeFloatingCaptions
            )
        }

        private var captionPanel: some View {
            captionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.48))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }

        private var captionContent: some View {
            let lines = captionLines

            return ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if shouldShowCaptionPlaceholder {
                            captionLine(
                                RealtimeCaptionLine(
                                    id: "placeholder",
                                    kind: .source,
                                    text: RealtimeCaptionDisplay.emptyPlaceholderText(isRunning: store.isRunning)
                                )
                            )
                            .opacity(0.72)
                        } else {
                            ForEach(lines) { line in
                                captionLine(line)
                                    .id(line.id)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("caption-bottom")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HeightReader(key: RealtimeCaptionScrollContentHeightKey.self))
                }
                .background(HeightReader(key: RealtimeCaptionScrollViewportHeightKey.self))
                .contentMargins(.horizontal, Self.contentHorizontalMargin, for: .scrollContent)
                .contentMargins(.vertical, Self.contentVerticalMargin, for: .scrollContent)
                .contentMargins(.trailing, Self.scrollIndicatorTrailingMargin, for: .scrollIndicators)
                .scrollIndicators(.visible)
                .onPreferenceChange(RealtimeCaptionScrollContentHeightKey.self) { height in
                    scrollContentHeight = height
                }
                .onPreferenceChange(RealtimeCaptionScrollViewportHeightKey.self) { height in
                    scrollViewportHeight = height
                }
                .onChange(of: lines) {
                    scrollToBottomIfNeeded(proxy)
                }
                .onChange(of: scrollContentHeight) {
                    scrollToBottomIfNeeded(proxy)
                }
            }
        }

        private var isCaptionContentScrollable: Bool {
            scrollContentHeight + Self.contentVerticalMargin * 2 > scrollViewportHeight
        }

        private func scrollToBottomIfNeeded(_ proxy: ScrollViewProxy) {
            guard !captionLines.isEmpty, isCaptionContentScrollable else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo("caption-bottom", anchor: .bottom)
            }
        }

        private func captionLine(_ line: RealtimeCaptionLine) -> some View {
            Text(line.text)
                .font(captionFont(for: line.kind))
                .foregroundStyle(captionForegroundStyle(for: line))
                .opacity(line.kind == .source && !line.isPending ? 0.82 : 1)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func captionForegroundStyle(for _: RealtimeCaptionLine) -> Color {
            .white
        }

        private func captionFont(for kind: RealtimeCaptionLine.Kind) -> Font {
            switch kind {
            case .source:
                return .system(size: 19, weight: .semibold)
            case .translation:
                return .system(size: 25, weight: .bold)
            }
        }

        private var captionControls: some View {
            HStack(spacing: 8) {
                captionDisplayModeButton
                recognitionControlButton
                if store.isPaused {
                    endRecognitionButton
                }
                clearCaptionButton
            }
        }

        private var captionDisplayModeButton: some View {
            Button {
                store.cycleCaptionDisplayMode()
            } label: {
                if let title = captionDisplayModeButtonTitle {
                    captionControlLabel(systemName: store.captionDisplayMode.systemImageName, title: title)
                } else {
                    captionControlIcon(systemName: store.captionDisplayMode.systemImageName)
                }
            }
            .buttonStyle(.plain)
            .help(store.captionDisplayMode.accessibilityLabel)
            .accessibilityLabel(Text(store.captionDisplayMode.accessibilityLabel))
        }

        private var closeCaptionButton: some View {
            Button {
                closeFloatingCaptions()
            } label: {
                captionControlIcon(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close captions")
            .accessibilityLabel(Text("Close captions"))
        }

        private var captionDisplayModeButtonTitle: String? {
            store.captionDisplayMode.buttonTitle(
                sourceLanguageName: preferences.realtimeSourceLanguage.primaryLabel,
                targetLanguageName: preferences.realtimeTargetLanguage.primaryLabel
            )
        }

        private var recognitionControlButton: some View {
            Button {
                Task {
                    await toggleRecognition()
                }
            } label: {
                captionControlIcon(systemName: recognitionControlSystemImage)
            }
            .buttonStyle(.plain)
            .disabled(store.isStarting || store.isStopping || (!store.isRunning && !store.hasRequiredLanguageSelection))
            .help(recognitionControlHelp)
            .accessibilityLabel(Text(recognitionControlAccessibilityLabel))
        }

        private var endRecognitionButton: some View {
            Button {
                Task {
                    await endRecognition()
                }
            } label: {
                captionControlIcon(systemName: "stop.fill")
            }
            .buttonStyle(.plain)
            .disabled(store.isStopping)
            .help("End realtime translation")
            .accessibilityLabel(Text("End realtime translation"))
        }

        private var clearCaptionButton: some View {
            Button {
                clearVisibleCaptions()
            } label: {
                captionControlIcon(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(captionLines.isEmpty)
            .help("Clear captions on screen")
            .accessibilityLabel(Text("Clear captions on screen"))
        }

        private func captionControlIcon(systemName: String) -> some View {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.42))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
        }

        private func captionControlLabel(systemName: String, title: String) -> some View {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.42))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
        }

        private var recognitionControlSystemImage: String {
            if store.isStarting || store.isStopping {
                return "hourglass"
            }
            return store.isRunning && !store.isPaused ? "pause.fill" : "play.fill"
        }

        private var recognitionControlAccessibilityLabel: String {
            if store.isStopping {
                return String(localized: "Stopping recognition")
            }
            if store.isRunning {
                return store.isPaused ? String(localized: "Resume recognition") : String(localized: "Pause recognition")
            }
            return String(localized: "Start recognition")
        }

        private var recognitionControlHelp: String {
            if store.hasRequiredLanguageSelection {
                return recognitionControlAccessibilityLabel
            }
            return preferences.realtimeTranslationProvider.performsTranslation
                ? "Choose source and target languages to start"
                : "Choose source language to start"
        }

        private func toggleRecognition() async {
            guard !store.isStopping else { return }
            if store.isRunning {
                store.togglePaused()
            } else {
                await store.start()
            }
        }

        private func endRecognition() async {
            await store.endSession()
        }

        private func closeFloatingCaptions() {
            store.showCaptions = RealtimeCaptionVisibility.closedValue(isVisible: store.showCaptions)
            RealtimeFloatingCaptionWindowController.close()
        }

        private func clearVisibleCaptions() {
            let lines = resolvedCaptionLines
            guard !lines.isEmpty else { return }
            captionClearAnchor = RealtimeCaptionDisplayClearAnchor(lines: lines)
        }
    }

    private struct HeightReader<Key: PreferenceKey>: View where Key.Value == CGFloat {
        let key: Key.Type

        var body: some View {
            GeometryReader { proxy in
                Color.clear.preference(key: key, value: proxy.size.height)
            }
        }
    }

    private struct RealtimeCaptionScrollContentHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private struct RealtimeCaptionScrollViewportHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private struct RealtimeFloatingWindowConfigurator: NSViewRepresentable {
        let mode: RealtimeCaptionWindowMode
        let privacyModeEnabled: Bool
        let notchSize: CGSize
        @Binding var targetScreenHasBuiltInNotch: Bool

        func makeNSView(context _: Context) -> NSView {
            NSView()
        }

        func updateNSView(_ view: NSView, context _: Context) {
            Task { @MainActor in
                guard let window = view.window else { return }

                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.backgroundColor = .clear
                window.isOpaque = false
                window.hasShadow = false
                window.sharingType = privacyModeEnabled ? .none : .readOnly

                switch mode {
                case .floating:
                    configureFloating(window)
                case .notch:
                    configureNotch(window)
                }
                syncTargetScreenState(window)
            }
        }

        private func configureFloating(_ window: NSWindow) {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.isMovableByWindowBackground = true
            window.styleMask.insert(.resizable)
            window.minSize = NSSize(width: 420, height: 120)
            keepWindowVisible(window)
        }

        private func configureNotch(_ window: NSWindow) {
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isMovableByWindowBackground = false
            window.styleMask.remove(.resizable)
            window.minSize = NSSize(width: notchSize.width, height: notchSize.height)
            positionNotchWindow(window)
        }

        private func keepWindowVisible(_ window: NSWindow) {
            guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }

            let inset: CGFloat = 16
            var frame = window.frame
            let maximumWidth = max(window.minSize.width, visibleFrame.width - inset * 2)
            let maximumHeight = max(window.minSize.height, visibleFrame.height - inset * 2)
            frame.size.width = min(max(frame.width, window.minSize.width), maximumWidth)
            frame.size.height = min(max(frame.height, window.minSize.height), maximumHeight)
            frame.origin.x = min(max(frame.origin.x, visibleFrame.minX + inset), visibleFrame.maxX - frame.width - inset)
            frame.origin.y = min(max(frame.origin.y, visibleFrame.minY + inset), visibleFrame.maxY - frame.height - inset)

            if frame != window.frame {
                window.setFrame(frame, display: true)
            }
        }

        private func positionNotchWindow(_ window: NSWindow) {
            guard let screen = window.screen ?? NSScreen.main else { return }
            let isCompact = notchSize == RealtimeNotchCaptionLayout.compactSize

            let frame = NSRect(
                x: RealtimeNotchCaptionLayout.originX(in: screen.frame, isCompact: isCompact),
                y: (screen.frame.maxY - notchSize.height).rounded(),
                width: notchSize.width,
                height: notchSize.height
            )
            if window.frame != frame {
                window.setFrame(frame, display: true)
            }
        }

        private func syncTargetScreenState(_ window: NSWindow) {
            let hasBuiltInNotch = mode == .notch && RealtimeNotchDisplay.hasBuiltInDisplayNotch(window.screen ?? NSScreen.main)
            if targetScreenHasBuiltInNotch != hasBuiltInNotch {
                targetScreenHasBuiltInNotch = hasBuiltInNotch
            }
        }
    }
#endif
