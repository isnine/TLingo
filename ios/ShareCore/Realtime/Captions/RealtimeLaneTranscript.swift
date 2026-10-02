#if os(macOS)
    import SwiftUI

    struct RealtimeLaneTranscript: View {
        @ObservedObject var store: RealtimeSessionStore
        let configurationID: UUID
        let snapshot: RealtimeLaneSnapshot?
        let colors: AppColors.Palette
        let phaseTitle: String

        @State private var scrollTask: Task<Void, Never>?

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let error = snapshot?.errorMessage, !error.isEmpty {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.body)
                                .foregroundStyle(colors.error)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if captionLines.isEmpty {
                            ContentUnavailableView {
                                Label(phaseTitle, systemImage: "waveform")
                            } description: {
                                Text(RealtimeCaptionDisplay.emptyPlaceholderText(isRunning: store.isRunning))
                            }
                            .frame(maxWidth: .infinity, minHeight: 220)
                        } else {
                            ForEach(captionLines) { line in
                                // Matches the iOS caption hierarchy, scaled down for side-by-side lanes.
                                Text(line.text)
                                    .font(
                                        line.kind == .source
                                            ? .system(size: 15, weight: .medium, design: .rounded)
                                            : .system(size: 20, weight: .semibold, design: .rounded)
                                    )
                                    .foregroundStyle(
                                        line.isPending
                                            ? colors.accent
                                            : (line.kind == .source ? colors.textSecondary : colors.textPrimary)
                                    )
                                    .lineSpacing(line.kind == .source ? 3 : 5)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .textSelection(.enabled)
                                    .id(line.id)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomID)
                        }
                    }
                    .padding(18)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: captionLines) {
                    scrollTask?.cancel()
                    scrollTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(60))
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
                .onDisappear {
                    scrollTask?.cancel()
                }
            }
        }

        private var captionLines: [RealtimeCaptionLine] {
            snapshot?.captionLines ?? []
        }

        private var bottomID: String {
            "realtime-lane-bottom-\(configurationID.uuidString)"
        }
    }
#endif
