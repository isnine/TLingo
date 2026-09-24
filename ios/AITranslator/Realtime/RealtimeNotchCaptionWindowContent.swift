#if os(macOS)
    import AppKit
    import CoreGraphics
    import ShareCore
    import SwiftUI

    @MainActor
    enum RealtimeNotchDisplay {
        static func preferredScreen() -> NSScreen? {
            let screens = NSScreen.screens
            if let notchedBuiltIn = screens.first(where: { hasBuiltInDisplayNotch($0) }) {
                return notchedBuiltIn
            }
            if let builtIn = screens.first(where: { isBuiltIn($0) }) {
                return builtIn
            }
            return NSScreen.main ?? screens.first
        }

        static func hasBuiltInDisplayNotch(_ screen: NSScreen?) -> Bool {
            guard let screen, isBuiltIn(screen) else { return false }
            let hasAuxiliaryTopArea = screen.auxiliaryTopLeftArea?.isEmpty == false ||
                screen.auxiliaryTopRightArea?.isEmpty == false
            return screen.safeAreaInsets.top > 0 &&
                hasAuxiliaryTopArea
        }

        static func isBuiltIn(_ screen: NSScreen) -> Bool {
            guard let id = displayID(for: screen) else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }

        static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CGDirectDisplayID(number.uint32Value)
        }
    }

    enum RealtimeNotchCaptionLayout {
        static let expandedSize = CGSize(width: 600, height: 150)
        static let compactSize = CGSize(width: 268, height: 38)
        static let compactTrailingExtension: CGFloat = 48

        static func size(isCompact: Bool) -> CGSize {
            isCompact ? compactSize : expandedSize
        }

        static func originX(in screenFrame: CGRect, isCompact: Bool) -> CGFloat {
            let centeredWidth = isCompact ? compactSize.width - compactTrailingExtension : expandedSize.width
            return (screenFrame.midX - centeredWidth / 2).rounded()
        }
    }

    private struct RealtimeNotchCaptionGroupWindow {
        let groups: [[RealtimeCaptionLine]]
        let startIndex: Int
    }

    struct RealtimeNotchCaptionWindowContent: View {
        private static let maximumVisibleCaptionLineCount = 6

        @ObservedObject var store: RealtimeSessionStore
        let captionLines: [RealtimeCaptionLine]
        let captionDisplayModeButtonTitle: String?
        let targetScreenHasBuiltInNotch: Bool
        let onToggleRecognition: () async -> Void
        let onEndRecognition: () async -> Void
        let onClearCaptions: () -> Void
        let onClose: () -> Void

        @State private var isHovering = false
        @State private var captionScrollOffset = 0

        var body: some View {
            let shape = RealtimeNotchCaptionShape()

            ZStack {
                shape
                    .fill(Color.black.opacity(0.98))
                shape
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    .mask(
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 2)
                            Color.white
                        }
                    )

                captionLayer
                    .padding(captionPadding)
                    .clipped()

                if !isCompact {
                    controls
                        .opacity(isHovering ? 1 : 0)
                        .allowsHitTesting(isHovering)
                        .accessibilityHidden(!isHovering)
                        .padding(.top, 8)
                        .padding(.trailing, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                if !isCompact, shouldShowScrollControls {
                    scrollControls
                        .opacity(isHovering ? 1 : 0)
                        .allowsHitTesting(isHovering)
                        .accessibilityHidden(!isHovering)
                        .padding(.trailing, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
            .frame(width: layoutSize.width, height: layoutSize.height)
            .contentShape(shape)
            .allowsWindowActivationEvents(true)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.25)) {
                    isHovering = hovering
                }
            }
            .onChange(of: captionLines) {
                clampCaptionScrollOffset()
            }
            .onChange(of: isCompact) {
                if isCompact {
                    captionScrollOffset = 0
                }
            }
            .animation(.easeInOut(duration: 0.22), value: isCompact)
        }

        private var isCompact: Bool {
            !store.isRunning || store.isPaused
        }

        private var layoutSize: CGSize {
            RealtimeNotchCaptionLayout.size(isCompact: isCompact)
        }

        private var captionPadding: EdgeInsets {
            if isCompact {
                return EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 8)
            }
            return EdgeInsets(top: targetScreenHasBuiltInNotch ? 42 : 12, leading: 22, bottom: 4, trailing: 58)
        }

        private var hidesCompactCaptionText: Bool {
            targetScreenHasBuiltInNotch
        }

        @ViewBuilder
        private var captionLayer: some View {
            if isCompact {
                compactCaptionContent
            } else {
                captionContent
            }
        }

        private var compactCaptionContent: some View {
            HStack(spacing: 8) {
                if hidesCompactCaptionText {
                    Spacer(minLength: 0)
                } else {
                    Text(compactCaptionText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                recognitionControlButton
                if store.isPaused {
                    endRecognitionButton
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }

        private var compactCaptionText: String {
            guard let group = visibleCaptionGroups.last else {
                return RealtimeCaptionDisplay.emptyPlaceholderText(isRunning: store.isRunning)
            }

            return group.last(where: { $0.kind == .translation })?.text ??
                group.last(where: { $0.kind == .source })?.text ??
                RealtimeCaptionDisplay.emptyPlaceholderText(isRunning: store.isRunning)
        }

        private var captionContent: some View {
            let groups = visibleCaptionGroups

            return VStack(alignment: .leading, spacing: 4) {
                if groups.isEmpty {
                    Text(RealtimeCaptionDisplay.emptyPlaceholderText(isRunning: store.isRunning))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                        captionGroup(group, isCurrent: index == groups.count - 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }

        private var visibleCaptionGroups: [[RealtimeCaptionLine]] {
            captionGroupWindow.groups
        }

        private var captionGroupWindow: RealtimeNotchCaptionGroupWindow {
            let groups = captionGroups
            guard !groups.isEmpty else {
                return RealtimeNotchCaptionGroupWindow(groups: [], startIndex: 0)
            }

            let endIndex = max(1, groups.count - min(captionScrollOffset, maxCaptionScrollOffset))
            var remainingLineCount = Self.maximumVisibleCaptionLineCount
            var visibleGroups: [[RealtimeCaptionLine]] = []
            var startIndex = endIndex

            for index in groups[..<endIndex].indices.reversed() {
                guard remainingLineCount > 0 else { break }

                let group = groups[index]
                let lineCount = group.count
                guard lineCount <= remainingLineCount else {
                    guard visibleGroups.isEmpty else { break }
                    visibleGroups.insert(Array(group.suffix(remainingLineCount)), at: 0)
                    startIndex = index
                    break
                }
                visibleGroups.insert(group, at: 0)
                startIndex = index
                remainingLineCount -= lineCount
            }

            return RealtimeNotchCaptionGroupWindow(groups: visibleGroups, startIndex: startIndex)
        }

        private var captionGroups: [[RealtimeCaptionLine]] {
            var groups: [[RealtimeCaptionLine]] = []
            var currentGroup: [RealtimeCaptionLine] = []

            for line in captionLines where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                switch line.kind {
                case .source:
                    if !currentGroup.isEmpty {
                        groups.append(currentGroup)
                        currentGroup = []
                    }
                    currentGroup.append(line)
                case .translation:
                    if currentGroup.contains(where: { $0.kind == .translation }) || currentGroup.isEmpty {
                        if !currentGroup.isEmpty {
                            groups.append(currentGroup)
                        }
                        currentGroup = [line]
                    } else {
                        currentGroup.append(line)
                    }
                }
            }

            if !currentGroup.isEmpty {
                groups.append(currentGroup)
            }

            return groups
        }

        private var maxCaptionScrollOffset: Int {
            max(captionGroups.count - 1, 0)
        }

        private var canScrollCaptionsUp: Bool {
            captionGroupWindow.startIndex > 0
        }

        private var canScrollCaptionsDown: Bool {
            captionScrollOffset > 0
        }

        private var shouldShowScrollControls: Bool {
            canScrollCaptionsUp || canScrollCaptionsDown
        }

        private var scrollControls: some View {
            VStack(spacing: 6) {
                scrollButton(
                    systemName: "chevron.up",
                    isEnabled: canScrollCaptionsUp,
                    help: "Scroll captions up",
                    action: scrollCaptionsUp
                )
                scrollButton(
                    systemName: "chevron.down",
                    isEnabled: canScrollCaptionsDown,
                    help: "Scroll captions down",
                    action: scrollCaptionsDown
                )
            }
        }

        private func scrollButton(
            systemName: String,
            isEnabled: Bool,
            help: String,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                controlIcon(systemName: systemName)
                    .opacity(isEnabled ? 1 : 0.36)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help(help)
            .accessibilityLabel(Text(help))
        }

        private func scrollCaptionsUp() {
            guard canScrollCaptionsUp else { return }
            captionScrollOffset = min(captionScrollOffset + 1, maxCaptionScrollOffset)
        }

        private func scrollCaptionsDown() {
            guard canScrollCaptionsDown else { return }
            captionScrollOffset = max(captionScrollOffset - 1, 0)
        }

        private func clampCaptionScrollOffset() {
            if captionLines.isEmpty {
                captionScrollOffset = 0
            } else {
                captionScrollOffset = min(captionScrollOffset, maxCaptionScrollOffset)
            }
        }

        private func captionGroup(_ group: [RealtimeCaptionLine], isCurrent: Bool) -> some View {
            let isBilingual = isBilingualCaptionGroup(group)

            return VStack(alignment: .leading, spacing: 1) {
                if let source = group.last(where: { $0.kind == .source }) {
                    captionLine(source, isCurrent: isCurrent, isBilingual: isBilingual)
                }
                if let translation = group.last(where: { $0.kind == .translation }) {
                    captionLine(translation, isCurrent: isCurrent, isBilingual: isBilingual)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func captionLine(_ line: RealtimeCaptionLine, isCurrent: Bool, isBilingual: Bool) -> some View {
            Text(line.text)
                .font(captionFont(for: line.kind, isCurrent: isCurrent))
                .foregroundStyle(captionForegroundStyle(for: line, isCurrent: isCurrent))
                .lineLimit(captionLineLimit(for: line.kind, isCurrent: isCurrent, isBilingual: isBilingual))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func captionLineLimit(
            for kind: RealtimeCaptionLine.Kind,
            isCurrent: Bool,
            isBilingual: Bool
        ) -> Int {
            guard isCurrent else { return 1 }
            guard isBilingual else { return Self.maximumVisibleCaptionLineCount }

            switch kind {
            case .source:
                return 3
            case .translation:
                return 3
            }
        }

        private func isBilingualCaptionGroup(_ group: [RealtimeCaptionLine]) -> Bool {
            group.contains(where: { $0.kind == .source }) && group.contains(where: { $0.kind == .translation })
        }

        private func captionFont(for kind: RealtimeCaptionLine.Kind, isCurrent: Bool) -> Font {
            switch kind {
            case .source:
                return .system(size: isCurrent ? 16 : 12, weight: .semibold)
            case .translation:
                return .system(size: isCurrent ? 16 : 12, weight: .bold)
            }
        }

        private func captionForegroundStyle(for line: RealtimeCaptionLine, isCurrent: Bool) -> Color {
            let opacity = line.kind == .source ? (isCurrent ? 0.7 : 0.48) : (isCurrent ? 1 : 0.62)
            return .white.opacity(opacity)
        }

        private var controls: some View {
            HStack(spacing: 8) {
                captionDisplayModeButton
                recognitionControlButton
                clearCaptionButton
                closeButton
            }
        }

        private var captionDisplayModeButton: some View {
            Button {
                store.cycleCaptionDisplayMode()
            } label: {
                if let captionDisplayModeButtonTitle {
                    controlLabel(systemName: store.captionDisplayMode.systemImageName, title: captionDisplayModeButtonTitle)
                } else {
                    controlIcon(systemName: store.captionDisplayMode.systemImageName)
                }
            }
            .buttonStyle(.plain)
            .help(store.captionDisplayMode.accessibilityLabel)
            .accessibilityLabel(Text(store.captionDisplayMode.accessibilityLabel))
        }

        private var recognitionControlButton: some View {
            Button {
                Task {
                    await onToggleRecognition()
                }
            } label: {
                controlIcon(systemName: recognitionControlSystemImage)
            }
            .buttonStyle(.plain)
            .disabled(store.isStarting || store.isStopping || (!store.isRunning && !store.hasRequiredLanguageSelection))
            .help(recognitionControlHelp)
            .accessibilityLabel(Text(recognitionControlAccessibilityLabel))
        }

        private var endRecognitionButton: some View {
            Button {
                Task {
                    await onEndRecognition()
                }
            } label: {
                controlIcon(systemName: "stop.fill")
            }
            .buttonStyle(.plain)
            .disabled(store.isStopping)
            .help("End realtime translation")
            .accessibilityLabel(Text("End realtime translation"))
        }

        private var clearCaptionButton: some View {
            Button(action: onClearCaptions) {
                controlIcon(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(captionLines.isEmpty)
            .help("Clear captions on screen")
            .accessibilityLabel(Text("Clear captions on screen"))
        }

        private var closeButton: some View {
            Button(action: onClose) {
                controlIcon(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close captions")
            .accessibilityLabel(Text("Close captions"))
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
            return store.primaryLaneConfiguration?.translationProvider.performsTranslation == false
                ? "Choose source language to start"
                : "Choose source and target languages to start"
        }

        private func controlIcon(systemName: String) -> some View {
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

        private func controlLabel(systemName: String, title: String) -> some View {
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
    }
#endif
