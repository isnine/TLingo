//
//  OnboardingStepRealtimePermissions.swift
//  TLingo
//
//  Realtime translation permissions guidance.
//

#if os(macOS)
    import AppKit
    import ShareCore
    import SwiftUI

    struct OnboardingStepRealtimePermissions: View {
        @ObservedObject var permissionManager: RealtimePermissionManager
        let colors: AppColorPalette

        var body: some View {
            VStack(spacing: 16) {
                OnboardingStepHeader(
                    systemImage: "waveform.and.mic",
                    iconColor: colors.accent,
                    title: "Realtime Translation",
                    subtitle: "Understand speech in realtime",
                    colors: colors
                )

                VStack(spacing: 10) {
                    permissionRow(
                        title: "Speech Recognition",
                        state: permissionManager.speechRecognition,
                        systemImage: "captions.bubble"
                    )

                    permissionRow(
                        title: "Microphone",
                        state: permissionManager.microphone,
                        systemImage: "mic"
                    )

                    permissionRow(
                        title: "Screen & System Audio Recording",
                        state: permissionManager.screenAndSystemAudio,
                        systemImage: "display.and.arrow.down"
                    )
                }

                if shouldShowRelaunchHint {
                    Button {
                        relaunchApp()
                    } label: {
                        Label("Relaunch TLingo", systemImage: "arrow.clockwise.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .tlingoGlassSurface(
                                cornerRadius: 8,
                                tint: colors.accent.opacity(0.10),
                                interactive: true,
                                fallbackTint: colors.accent.opacity(0.06),
                                fallbackStroke: colors.accent.opacity(0.32)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(colors.accent)

                    Text("Screen & System Audio Recording only takes effect after TLingo restarts.")
                        .font(.system(size: 11))
                        .foregroundColor(colors.textSecondary.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("After enabling Screen & System Audio Recording, macOS may require quitting and reopening TLingo.")
                        .font(.system(size: 11))
                        .foregroundColor(colors.textSecondary.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .onAppear {
                permissionManager.refresh()
                permissionManager.startPolling()
            }
            .onDisappear {
                permissionManager.stopPolling()
            }
        }

        private var shouldShowRelaunchHint: Bool {
            permissionManager.hasRequestedInitialPermissions
                && !permissionManager.allGranted
                && !permissionManager.screenAndSystemAudio.isGranted
        }

        private func relaunchApp() {
            let url = Bundle.main.bundleURL
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-n", url.path]
            try? task.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }

        private func permissionRow(
            title: LocalizedStringKey,
            state: RealtimePermissionState,
            systemImage: String
        ) -> some View {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(colors.accent)
                    .frame(width: 28, height: 28)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(colors.textPrimary)

                Spacer()

                HStack(spacing: 5) {
                    Image(systemName: statusDisplay(for: state).icon)
                        .font(.system(size: 13, weight: .semibold))
                    Text(statusDisplay(for: state).title)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(statusDisplay(for: state).color)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(colors.cardBackground)
            )
        }

        private func statusDisplay(
            for state: RealtimePermissionState
        ) -> (title: LocalizedStringKey, icon: String, color: Color) {
            switch state {
            case .granted:
                return ("Granted", "checkmark.circle.fill", .green)
            case .denied:
                return ("Enable", "exclamationmark.circle.fill", .orange)
            case .notDetermined:
                return ("Requested", "circle", colors.textSecondary)
            case .unknown:
                return ("Checking", "circle", colors.textSecondary)
            }
        }
    }
#endif
