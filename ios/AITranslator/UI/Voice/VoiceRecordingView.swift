//
//  VoiceRecordingView.swift
//  TLingo
//

import ShareCore
import SwiftUI

struct VoiceRecordingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var speechService = SpeechRecognitionService()
    let onComplete: (String) -> Void
    let onCancel: () -> Void

    @State private var lastTapTime: Date = .distantPast
    @State private var showPermissionAlert = false
    @State private var confirmedTranscript: String?

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            if let transcript = confirmedTranscript {
                transcriptConfirmation(transcript)
            } else {
                micButton

                stateLabel

                if speechService.state == .recording {
                    guidanceLabel
                }

                actionButtons
            }

            Spacer()
        }
        .padding(24)
        .background(colors.background.ignoresSafeArea())
        .presentationBackground(colors.background)
        .onChange(of: speechService.transcript) { _, newValue in
            let text = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                withAnimation {
                    confirmedTranscript = text
                }
            }
        }
        .alert("Permission Required", isPresented: $showPermissionAlert) {
            Button {
                #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                #endif
            } label: {
                Text("Open Settings", comment: "Open system settings for permissions")
            }
            Button("Cancel", role: .cancel) {
                onCancel()
            }
        } message: {
            Text(
                "Microphone permission is required. Please enable it in Settings.",
                comment: "Permission denied alert message"
            )
        }
    }

    // MARK: - Transcript Confirmation

    private func transcriptConfirmation(_ transcript: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.green)

            VStack(spacing: 8) {
                Text("Here's what I heard:", comment: "Transcript confirmation header")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(colors.textPrimary)

                Text(transcript)
                    .font(.system(size: 15))
                    .foregroundColor(colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            HStack(spacing: 16) {
                Button {
                    confirmedTranscript = nil
                    speechService.cancelRecording()
                } label: {
                    Text("Re-record", comment: "Re-record voice")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(colors.textSecondary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            Capsule().fill(colors.cardBackground)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    onComplete(transcript)
                } label: {
                    Text("Continue", comment: "Confirm transcript and continue")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [colors.accent, colors.accent.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Recording UI

    private var micButton: some View {
        Button {
            guard Date().timeIntervalSince(lastTapTime) > 0.3 else { return }
            lastTapTime = Date()

            switch speechService.state {
            case .idle:
                beginRecording()
            case .recording:
                speechService.stopRecording()
            default:
                break
            }
        } label: {
            ZStack {
                Circle()
                    .fill(micButtonGradient)
                    .frame(width: 80, height: 80)
                    .scaleEffect(speechService.state == .recording ? 1.1 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: speechService.state == .recording
                    )

                if speechService.state == .preparing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: speechService.state == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(speechService.state == .processing || speechService.state == .preparing)
    }

    private var micButtonGradient: LinearGradient {
        if speechService.state == .recording {
            LinearGradient(
                colors: [.red, .orange],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
                colors: [colors.accent, colors.accent.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var stateLabel: some View {
        Group {
            switch speechService.state {
            case .preparing:
                Text("Preparing microphone...", comment: "Microphone initializing")
                    .font(.system(size: 14))
            case .recording:
                VStack(spacing: 6) {
                    Text("Listening...", comment: "Voice recording state")
                        .font(.system(size: 16, weight: .semibold))
                    Text(formattedDuration)
                        .font(.system(size: 28, weight: .light).monospacedDigit())
                }
            case .paused:
                Text("Paused", comment: "Voice recording paused state")
                    .font(.system(size: 16, weight: .semibold))
            case .processing:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Transcribing...", comment: "Whisper transcription in progress")
                        .font(.system(size: 14))
                }
            case .idle:
                if let error = speechService.error {
                    Text(error.localizedDescription)
                        .font(.system(size: 14))
                        .foregroundColor(colors.error)
                        .multilineTextAlignment(.center)
                } else {
                    VStack(spacing: 12) {
                        Text("Describe the action you want, the more detail the better.", comment: "Voice recording idle guidance")
                            .font(.system(size: 14))
                            .multilineTextAlignment(.center)
                        Text("e.g. \"Translate to formal Japanese and show side-by-side comparison\"", comment: "Voice recording example")
                            .font(.system(size: 13, weight: .medium))
                            .italic()
                            .multilineTextAlignment(.center)
                            .foregroundColor(colors.textSecondary.opacity(0.6))
                        Text("Tap the mic to start", comment: "Voice recording idle hint")
                            .font(.system(size: 13))
                            .padding(.top, 4)
                    }
                }
            @unknown default:
                EmptyView()
            }
        }
        .foregroundColor(colors.textSecondary)
    }

    private var guidanceLabel: some View {
        Text("Describe what you want the action to do — the more detail, the better.", comment: "Voice recording guidance")
            .font(.system(size: 13))
            .foregroundColor(colors.textSecondary.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button {
                speechService.cancelRecording()
                onCancel()
            } label: {
                Text("Cancel", comment: "Cancel voice recording")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(colors.textSecondary)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(colors.cardBackground)
                    )
            }
            .buttonStyle(.plain)

            if speechService.state == .recording {
                Button {
                    guard Date().timeIntervalSince(lastTapTime) > 0.3 else { return }
                    lastTapTime = Date()
                    speechService.stopRecording()
                } label: {
                    Text("Done", comment: "Finish voice recording")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [colors.accent, colors.accent.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var formattedDuration: String {
        let total = Int(speechService.recordingDuration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func beginRecording() {
        Task {
            let authorized = await speechService.requestAuthorization()
            guard authorized else {
                showPermissionAlert = true
                return
            }
            await speechService.startRecording()
        }
    }
}
