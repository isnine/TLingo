#if os(macOS)
    import ShareCore
    import SwiftUI

    struct RealtimeInspectorView: View {
        @Environment(\.colorScheme) private var colorScheme
        @ObservedObject var preferences: AppPreferences

        @Binding var isFloatingCaptionVisible: Bool
        @Binding var isAdvancedSettingsExpanded: Bool

        let isBusy: Bool
        let recordingBinding: Binding<Bool>
        let captionWindowModeBinding: Binding<RealtimeCaptionWindowMode>
        let captionPrivacyBinding: Binding<Bool>
        let onFloatingCaptionVisibilityChanged: (Bool) -> Void

        private var colors: AppColorPalette {
            AppColors.Palette(colorScheme: colorScheme, accentTheme: preferences.accentTheme)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Realtime Options")
                    .font(.title2)
                    .bold()
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                Form {
                    Section {
                        Toggle(isOn: floatingCaptionBinding) {
                            Label("Live Captions", systemImage: "captions.bubble")
                        }
                        .toggleStyle(.switch)
                        .help("Show live captions on screen")
                    }

                    Section {
                        Toggle(isOn: $isAdvancedSettingsExpanded) {
                            HStack {
                                Label("Advanced Settings", systemImage: "slider.horizontal.3")
                                    .foregroundStyle(colors.textPrimary)

                                Spacer()

                                Image(systemName: isAdvancedSettingsExpanded ? "chevron.up" : "chevron.down")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .toggleStyle(.button)
                        .buttonStyle(.plain)

                        if isAdvancedSettingsExpanded {
                            advancedSettings
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            .animation(.easeInOut(duration: 0.16), value: isAdvancedSettingsExpanded)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(colors.cardBackground.opacity(colorScheme == .dark ? 0.24 : 0.60))
        }

        private var floatingCaptionBinding: Binding<Bool> {
            Binding(
                get: { isFloatingCaptionVisible },
                set: { onFloatingCaptionVisibilityChanged($0) }
            )
        }

        @ViewBuilder
        private var advancedSettings: some View {
            Toggle(isOn: recordingBinding) {
                Label("Record Mac Audio and Microphone", systemImage: "waveform.and.mic")
            }
            .toggleStyle(.switch)
            .disabled(isBusy)
            .help("Save both Mac Audio and Microphone recordings with realtime history")

            if isFloatingCaptionVisible {
                Picker("Window Style", selection: captionWindowModeBinding) {
                    ForEach(RealtimeCaptionWindowMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help(preferences.realtimeCaptionWindowMode.settingsDescription)

                Toggle(isOn: captionPrivacyBinding) {
                    Label("Hide from Screen Sharing", systemImage: "eye.slash")
                }
                .toggleStyle(.switch)
                .help("Best-effort hiding for screen sharing and recording")
            }
        }
    }
#endif
