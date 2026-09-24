#if os(macOS)
    import SwiftUI

    struct RealtimeLaneHeader: View {
        @ObservedObject var store: RealtimeSessionStore
        let configuration: RealtimeLaneConfiguration
        let snapshot: RealtimeLaneSnapshot?
        let colors: AppColors.Palette
        let sourceLanguage: SourceLanguageOption
        let phaseTitle: String
        let phaseColor: Color

        private var isBusy: Bool {
            store.isRunning || store.isStarting || store.isStopping
        }

        private var isPrimary: Bool {
            store.primaryLaneID == configuration.id
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    RealtimeLaneModelMenu(
                        store: store,
                        configuration: configuration,
                        colors: colors,
                        sourceLanguage: sourceLanguage,
                        isBusy: isBusy
                    )

                    Image(systemName: "arrow.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    providerMenu

                    Spacer(minLength: 8)

                    Button(
                        isPrimary ? "Primary realtime lane" : "Use for floating captions",
                        systemImage: isPrimary ? "pin.fill" : "pin"
                    ) {
                        store.setPrimaryLane(id: configuration.id)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(isPrimary ? colors.accent : colors.textSecondary)
                    .help(isPrimary ? "Primary realtime lane" : "Use for floating captions")

                    Button("Close realtime lane", systemImage: "xmark") {
                        Task {
                            await store.removeLane(id: configuration.id)
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(colors.textSecondary)
                    .disabled(store.laneConfigurations.count <= 1)
                    .help("Close realtime lane")
                }

                ViewThatFits(in: .horizontal) {
                    statusRow(showsLatency: true)

                    VStack(alignment: .leading, spacing: 4) {
                        statusRow(showsLatency: false)

                        if isPrimary, let latency = snapshot?.latency {
                            latencyText(latency)
                        }
                    }
                }
                .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(colors.cardBackground)
        }

        private func latencyLabel(_ latency: RealtimeLaneLatency) -> String {
            """
            \(String(localized: "Recognition")) \(latency.recognitionMilliseconds) · \
            \(String(localized: "Translation")) \(latency.translationMilliseconds) · \
            \(String(localized: "Total")) \(latency.totalMilliseconds) ms
            """
        }

        private func latencyText(_ latency: RealtimeLaneLatency) -> some View {
            Text(latencyLabel(latency))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        private func statusRow(showsLatency: Bool) -> some View {
            HStack(spacing: 7) {
                Circle()
                    .fill(phaseColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                if isPrimary {
                    Text("Primary")
                        .foregroundStyle(colors.accent)

                    if showsLatency, let latency = snapshot?.latency {
                        latencyText(latency)
                    }
                }

                Text(phaseTitle)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if snapshot?.startedOffset ?? 0 > 0 {
                    Text("+\((snapshot?.startedOffset ?? 0).clockLabel)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }

        private var providerMenu: some View {
            Menu {
                ForEach(RealtimeTranslationProvider.availableCases) { provider in
                    Button {
                        store.updateLane(
                            id: configuration.id,
                            recognitionModelID: configuration.recognitionModelID,
                            translationProvider: provider
                        )
                    } label: {
                        if provider == configuration.translationProvider {
                            Label(provider.title, systemImage: "checkmark")
                        } else {
                            Text(provider.title)
                        }
                    }
                }
            } label: {
                Text(configuration.translationProvider.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 0)
            .disabled(isBusy)
        }
    }
#endif
