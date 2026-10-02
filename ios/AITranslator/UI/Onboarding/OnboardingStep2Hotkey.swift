//
//  OnboardingStep2Hotkey.swift
//  TLingo
//
//  Step 2 of first-launch onboarding: set Quick Translate hotkey.
//

#if os(macOS)
    import AppKit
    import Carbon
    import ShareCore
    import SwiftUI

    struct OnboardingStep2Hotkey: View {
        @ObservedObject var hotKeyManager: HotKeyManager
        @Binding var isRecording: Bool
        @Binding var monitor: Any?
        let colors: AppColorPalette

        var body: some View {
            VStack(spacing: 16) {
                OnboardingStepHeader(
                    systemImage: "bolt.fill",
                    iconColor: .orange,
                    title: "Translate text with a shortcut",
                    subtitle: "Open TLingo from any app with a key combination.",
                    colors: colors
                )

                let config = hotKeyManager.quickTranslateConfiguration
                HStack(spacing: 10) {
                    Button {
                        if isRecording {
                            stopRecording()
                        } else {
                            startRecording()
                        }
                    } label: {
                        Text(isRecording ? String(localized: "Press keys...") : config.displayString)
                            .font(.system(size: 15, weight: .medium, design: config.isEmpty ? .default : .monospaced))
                            .foregroundColor(
                                isRecording
                                    ? colors.accent
                                    : (config.isEmpty ? colors.textSecondary : colors.textPrimary)
                            )
                            .frame(minWidth: 160)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .tlingoGlassCapsule(
                                tint: isRecording ? colors.accent.opacity(0.18) : colors.cardBackground.opacity(0.12),
                                interactive: true,
                                fallbackTint: isRecording ? colors.accent.opacity(0.12) : colors.inputBackground.opacity(0.86),
                                fallbackStroke: isRecording ? colors.accent.opacity(0.45) : colors.divider
                            )
                    }
                    .buttonStyle(.plain)

                    if !config.isEmpty {
                        Button {
                            hotKeyManager.clearConfiguration(for: .quickTranslate)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 18))
                                .foregroundColor(colors.textSecondary.opacity(0.6))
                                .frame(width: 30, height: 30)
                                .tlingoGlassCircle(.control, interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Requires at least one modifier key. Press Escape to cancel.")
                    .font(.system(size: 12))
                    .foregroundColor(colors.textSecondary)

                Spacer(minLength: 0)
            }
            .onDisappear {
                stopRecording()
            }
        }

        // TODO: Extract this recorder into a reusable HotKeyRecorderButton component
        // and share with SettingsView.swift (lines 557-592) in a future cleanup.
        private func startRecording() {
            isRecording = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
                guard event.type == .keyDown else { return event }

                let modifiers = event.modifierFlags.carbonModifiers
                let keyCode = UInt32(event.keyCode)

                if keyCode == 53 {
                    stopRecording()
                    return nil
                }

                let isFunctionKey = (keyCode >= 122 && keyCode <= 135) || (keyCode >= 96 && keyCode <= 111)
                if modifiers == 0, !isFunctionKey {
                    return nil
                }

                let config = HotKeyConfiguration(keyCode: keyCode, modifiers: modifiers)
                hotKeyManager.updateConfiguration(config, for: .quickTranslate)
                stopRecording()
                return nil
            }
        }

        private func stopRecording() {
            isRecording = false
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
#endif
