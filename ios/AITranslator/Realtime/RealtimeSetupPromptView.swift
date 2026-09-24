#if os(macOS)
    import ShareCore
    import SwiftUI

    struct RealtimeSetupPromptView: View {
        @Environment(\.colorScheme) private var colorScheme
        @ObservedObject var store: RealtimeSessionStore
        @ObservedObject var preferences: AppPreferences
        @ObservedObject var permissionManager: RealtimePermissionManager

        @Binding var isOnboardingPresented: Bool

        let inspectorTrailingPadding: CGFloat

        private var colors: AppColorPalette {
            AppColors.Palette(colorScheme: colorScheme, accentTheme: preferences.accentTheme)
        }

        @ViewBuilder
        var body: some View {
            if shouldShowPrompt {
                Group {
                    if let missingPermissionKind {
                        setupPromptBanner {
                            Image(systemName: permissionSystemImage(for: missingPermissionKind))
                                .font(.headline)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(permissionTitle(for: missingPermissionKind))
                                    .font(.caption.bold())
                                Text(permissionMessage(for: missingPermissionKind))
                                    .font(.caption)
                                    .foregroundStyle(colors.textSecondary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 12)

                            Button {
                                handleMissingPermission()
                            } label: {
                                Label(
                                    permissionButtonTitle(for: missingPermissionKind),
                                    systemImage: "gearshape"
                                )
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(.bordered)
                            .layoutPriority(1)
                        }
                    } else if setupRequirement == .languageSelection {
                        setupPromptBanner {
                            Image(systemName: "globe")
                                .font(.headline)
                            Text(languagePromptText)
                                .font(.caption.bold())
                                .lineLimit(1)
                            Spacer(minLength: 12)
                        }
                    }
                }
                .padding(.leading, 20)
                .padding(.trailing, inspectorTrailingPadding)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }
        }

        private var shouldShowPrompt: Bool {
            guard !SnapshotLaunchArguments.isSnapshotMode() else { return false }
            return missingPermissionKind != nil || setupRequirement == .languageSelection
        }

        private var missingPermissionKind: RealtimePermissionKind? {
            switch store.inputSource {
            case .macAudio where !permissionManager.screenAndSystemAudio.isGranted:
                return .screenAndSystemAudio
            case .microphone where !permissionManager.microphone.isGranted:
                return .microphone
            default:
                break
            }

            let needsSpeechRecognitionPermission = store.laneConfigurations.contains {
                $0.recognitionModel.runtime == .appleSpeech
            }
            if needsSpeechRecognitionPermission && !permissionManager.speechRecognition.isGranted {
                return .speechRecognition
            }

            return nil
        }

        private var setupRequirement: RealtimeSetupPromptRequirement {
            RealtimeSetupPromptRequirement.evaluate(
                hasMissingPermission: missingPermissionKind != nil,
                sourceLanguage: preferences.realtimeSourceLanguage,
                targetLanguage: preferences.realtimeTargetLanguage,
                requiresTargetLanguage: store.primaryLaneConfiguration?.translationProvider.performsTranslation ?? true
            )
        }

        private var languagePromptText: LocalizedStringKey {
            store.primaryLaneConfiguration?.translationProvider.performsTranslation == false
                ? "Choose source language before starting realtime translation."
                : "Choose source and target languages before starting realtime translation."
        }

        private func setupPromptBanner<Content: View>(@ViewBuilder content: () -> Content) -> some View {
            HStack(spacing: 10) {
                content()
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .tlingoGlassSurface(
                cornerRadius: 12,
                tint: Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10),
                fallbackTint: Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10),
                fallbackStroke: Color.orange.opacity(0.28)
            )
        }

        private func handleMissingPermission() {
            isOnboardingPresented = true
        }

        private func permissionTitle(for kind: RealtimePermissionKind) -> LocalizedStringKey {
            switch kind {
            case .speechRecognition:
                return "Speech Recognition Permission Required"
            case .microphone:
                return "Microphone Permission Required"
            case .screenAndSystemAudio:
                return "Screen & System Audio Recording Required"
            }
        }

        private func permissionButtonTitle(for _: RealtimePermissionKind) -> LocalizedStringKey {
            "Set Up"
        }

        private func permissionMessage(for kind: RealtimePermissionKind) -> LocalizedStringKey {
            switch kind {
            case .speechRecognition:
                return "Realtime captions need Speech Recognition access to transcribe audio."
            case .microphone:
                return "Microphone input needs microphone access before realtime captions can start."
            case .screenAndSystemAudio:
                return "Mac Audio needs Screen & System Audio Recording access. Look for TLingo in the list."
            }
        }

        private func permissionSystemImage(for kind: RealtimePermissionKind) -> String {
            switch kind {
            case .speechRecognition:
                return "captions.bubble"
            case .microphone:
                return "mic.fill"
            case .screenAndSystemAudio:
                return "display.and.arrow.down"
            }
        }
    }
#endif
