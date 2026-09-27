#if os(macOS)
    import ShareCore
    import SwiftUI

    struct RealtimeSetupPromptView: View {
        @ObservedObject var store: RealtimeSessionStore
        @ObservedObject var preferences: AppPreferences
        @ObservedObject var permissionManager: RealtimePermissionManager

        @Binding var isOnboardingPresented: Bool

        let inspectorTrailingPadding: CGFloat
        let startBlocker: RealtimeStartBlocker?
        let onImportAudio: () -> Void

        var body: some View {
            if !SnapshotLaunchArguments.isSnapshotMode(), let notice {
                RealtimeNoticeBanner(notice: notice)
                    .padding(.leading, 20)
                    .padding(.trailing, inspectorTrailingPadding)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
            }
        }

        private var notice: RealtimeNotice? {
            if let missingPermissionKind {
                return RealtimeNotice(
                    systemImage: permissionSystemImage(for: missingPermissionKind),
                    title: permissionTitle(for: missingPermissionKind),
                    message: Text(permissionMessage(for: missingPermissionKind)),
                    action: RealtimeNotice.Action(
                        title: permissionButtonTitle(for: missingPermissionKind),
                        systemImage: "gearshape",
                        perform: handleMissingPermission
                    )
                )
            }
            if setupRequirement == .languageSelection {
                return RealtimeNotice(
                    systemImage: "globe",
                    title: "Choose Languages",
                    message: Text(languagePromptText),
                    action: nil
                )
            }
            if let startBlocker, let message = startBlocker.errorDescription {
                switch startBlocker {
                case .starting, .stopping:
                    return nil
                default:
                    return RealtimeNotice(
                        systemImage: startBlockerSystemImage(for: startBlocker),
                        title: "Can’t Start Realtime Translation",
                        message: Text(verbatim: message),
                        action: startBlockerAction(for: startBlocker)
                    )
                }
            }
            return nil
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
            if needsSpeechRecognitionPermission, !permissionManager.speechRecognition.isGranted {
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

        private func startBlockerSystemImage(for blocker: RealtimeStartBlocker) -> String {
            switch blocker {
            case .importedAudioRequired:
                return "waveform.badge.plus"
            case .memoryPressure, .tooManyLocalRecognitionModels:
                return "memorychip"
            case .missingLanguageSelection:
                return "globe"
            case .missingAzureConfiguration:
                return "key"
            default:
                return "exclamationmark.triangle.fill"
            }
        }

        private func startBlockerAction(for blocker: RealtimeStartBlocker) -> RealtimeNotice.Action? {
            guard case .importedAudioRequired = blocker else { return nil }
            return RealtimeNotice.Action(
                title: "Import Audio",
                systemImage: "square.and.arrow.down",
                perform: onImportAudio
            )
        }
    }

    struct RealtimeNotice {
        struct Action {
            let title: LocalizedStringKey
            let systemImage: String
            let perform: () -> Void
        }

        let systemImage: String
        let title: LocalizedStringKey
        let message: Text
        let action: Action?
    }

    /// Shared inline notice for realtime setup, permission, and start-blocker states.
    struct RealtimeNoticeBanner: View {
        @Environment(\.colorScheme) private var colorScheme

        let notice: RealtimeNotice

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: notice.systemImage)
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                    notice.message
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 12)

                if let action = notice.action {
                    Button(action: action.perform) {
                        Label(action.title, systemImage: action.systemImage)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .layoutPriority(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .tlingoGlassSurface(
                cornerRadius: 12,
                tint: Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10),
                fallbackTint: Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10),
                fallbackStroke: Color.orange.opacity(0.28)
            )
        }
    }
#endif
