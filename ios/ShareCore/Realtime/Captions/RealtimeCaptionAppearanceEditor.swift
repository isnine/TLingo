import SwiftUI

public struct RealtimeCaptionAppearanceEditor: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var preferences: AppPreferences
    let mode: RealtimeCaptionDisplayMode

    public init(preferences: AppPreferences, mode: RealtimeCaptionDisplayMode) {
        self.preferences = preferences
        self.mode = mode
    }

    private var appearance: RealtimeCaptionAppearance {
        preferences.realtimeCaptionAppearance
    }

    private var palette: AppColors.Palette {
        AppColors.Palette(colorScheme: colorScheme, accentTheme: preferences.accentTheme)
    }

    public var body: some View {
        Form {
            Section("Preview") {
                VStack(alignment: .leading, spacing: 6 * appearance.spacing.scale) {
                    if mode != .translationOnly {
                        Text(verbatim: "Welcome to TLingo.")
                            .font(.system(
                                size: mode == .bilingual ? appearance.textSize * 17 / 22 : appearance.textSize,
                                design: fontDesign
                            ))
                            .foregroundStyle(appearance.sourceTextColor(
                                fallback: mode == .bilingual ? palette.textSecondary : palette.textPrimary
                            ))
                    }
                    if mode != .sourceOnly {
                        Text(verbatim: "欢迎使用 TLingo。")
                            .font(.system(size: appearance.textSize, design: fontDesign))
                            .foregroundStyle(appearance.translationTextColor(fallback: palette.textPrimary))
                    }
                }
                .lineSpacing(2 * appearance.spacing.scale)
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                .padding(16)
                .background(appearance.captionBackgroundColor(fallback: palette.cardBackground))
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityIdentifier("realtime_caption_preview")
            }

            Section("Text") {
                Picker("Font", selection: binding(\.fontDesign)) {
                    #if os(macOS)
                        Text("Automatic").tag(RealtimeCaptionAppearance.FontDesign.platformDefault)
                    #endif
                    Text("Serif").tag(RealtimeCaptionAppearance.FontDesign.serif)
                    Text("System").tag(RealtimeCaptionAppearance.FontDesign.system)
                    Text("Rounded").tag(RealtimeCaptionAppearance.FontDesign.rounded)
                }
                LabeledContent("Text Size", value: "\(Int(appearance.textSize)) pt")
                Slider(value: binding(\.textSize), in: RealtimeCaptionAppearance.textSizeRange, step: 1) {
                    Text("Text Size")
                }
                Picker("Line Spacing", selection: binding(\.spacing)) {
                    Text("Compact").tag(RealtimeCaptionAppearance.Spacing.compact)
                    Text("Standard").tag(RealtimeCaptionAppearance.Spacing.standard)
                    Text("Relaxed").tag(RealtimeCaptionAppearance.Spacing.relaxed)
                }
            }

            Section("Text Colors") {
                colorControl("Source Color", keyPath: \.sourceColor, fallback: palette.textSecondary)
                colorControl("Translation Color", keyPath: \.translationColor, fallback: palette.textPrimary)
            }

            Section {
                colorControl("Background Color", keyPath: \.backgroundColor, fallback: palette.cardBackground)
                #if os(macOS)
                    LabeledContent(
                        "Floating Background Opacity",
                        value: "\(Int((appearance.floatingBackgroundOpacity * 100).rounded()))%"
                    )
                    Slider(value: binding(\.floatingBackgroundOpacity), in: 0 ... 1, step: 0.01) {
                        Text("Floating Background Opacity")
                    }
                #endif
            } header: {
                Text("Background")
            } footer: {
                #if os(macOS)
                    Text("Opacity applies only to floating captions. Notch captions keep a black background.")
                #else
                    Text("Applies to captions here and in Picture in Picture. Backgrounds stay opaque.")
                #endif
            }

            Section {
                Button("Reset Caption Appearance") {
                    preferences.setRealtimeCaptionAppearance(RealtimeCaptionAppearance())
                }
                .disabled(appearance == RealtimeCaptionAppearance())
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
            .navigationTitle("Caption Appearance")
        #endif
    }

    private var fontDesign: Font.Design {
        switch appearance.fontDesign {
        case .platformDefault:
            #if os(macOS)
                .rounded
            #else
                .serif
            #endif
        case .serif: .serif
        case .system: .default
        case .rounded: .rounded
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<RealtimeCaptionAppearance, Value>) -> Binding<Value> {
        Binding(
            get: { preferences.realtimeCaptionAppearance[keyPath: keyPath] },
            set: { value in
                var updated = preferences.realtimeCaptionAppearance
                updated[keyPath: keyPath] = value
                preferences.setRealtimeCaptionAppearance(updated)
            }
        )
    }

    private func colorControl(
        _ title: LocalizedStringKey,
        keyPath: WritableKeyPath<RealtimeCaptionAppearance, RealtimeCaptionColor?>,
        fallback: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ColorPicker(title, selection: Binding(
                get: { appearance[keyPath: keyPath]?.color ?? fallback },
                set: { binding(keyPath).wrappedValue = RealtimeCaptionColor(color: $0) }
            ), supportsOpacity: false)
            Toggle("Automatic", isOn: Binding(
                get: { appearance[keyPath: keyPath] == nil },
                set: { automatic in
                    binding(keyPath).wrappedValue = automatic ? nil : RealtimeCaptionColor(color: fallback)
                }
            ))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }
}

public extension View {
    func realtimeCaptionAppearancePopover(
        isPresented: Binding<Bool>,
        preferences: AppPreferences,
        mode: RealtimeCaptionDisplayMode
    ) -> some View {
        popover(isPresented: isPresented) {
            RealtimeCaptionAppearanceEditor(
                preferences: preferences,
                mode: mode
            )
            .frame(width: 380, height: 560)
        }
    }
}
