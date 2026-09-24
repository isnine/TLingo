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
                    LazyVStack(alignment: .leading, spacing: 12) {
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
                                Text(line.text)
                                    .font(line.kind == .source ? .body : .headline)
                                    .foregroundStyle(
                                        line.isPending
                                            ? colors.accent
                                            : (line.kind == .source ? colors.textSecondary : colors.textPrimary)
                                    )
                                    .lineSpacing(2)
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
