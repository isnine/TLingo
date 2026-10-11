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
            Form {
                Section {
                    Toggle("Live Captions", isOn: floatingCaptionBinding)
                        .help("Show live captions on screen")

                    if isFloatingCaptionVisible {
                        LabeledContent("Window Style") {
                            Picker("Window Style", selection: captionWindowModeBinding) {
                                ForEach(RealtimeCaptionWindowMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        .help(preferences.realtimeCaptionWindowMode.settingsDescription)

                        Toggle("Hide from Screen Sharing", isOn: captionPrivacyBinding)
                            .help("Best-effort hiding for screen sharing and recording")
                    }
                } header: {
                    Text("Realtime Options")
                }

                Section {
                    DisclosureGroup("Advanced Settings", isExpanded: $isAdvancedSettingsExpanded) {
                        Toggle("Record Mac Audio and Microphone", isOn: recordingBinding)
                            .disabled(isBusy)
                            .help("Save both Mac Audio and Microphone recordings with realtime history")
                    }
                }
            }
            .formStyle(CardFormStyle(colors: colors, maxWidth: .infinity, horizontalPadding: 12))
            .animation(.easeInOut(duration: 0.16), value: isAdvancedSettingsExpanded)
            .animation(.easeInOut(duration: 0.16), value: isFloatingCaptionVisible)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(colors.background.ignoresSafeArea())
        }

        private var floatingCaptionBinding: Binding<Bool> {
            Binding(
                get: { isFloatingCaptionVisible },
                set: { onFloatingCaptionVisibilityChanged($0) }
            )
        }
    }
#endif
