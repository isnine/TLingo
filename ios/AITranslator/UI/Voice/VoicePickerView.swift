//
//  VoicePickerView.swift
//  AITranslator
//
//  Created by AI Assistant on 2025/02/02.
//

import ShareCore
import SwiftUI

struct VoicePickerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isPresented: Bool
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var ttsPreviewService = TTSPreviewService.shared

    @State private var voices: [VoiceConfig] = []
    @State private var isLoading = true

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        #if os(macOS)
            macOSContent
        #else
            iOSContent
        #endif
    }

    // MARK: - macOS Content

    #if os(macOS)
        private var macOSContent: some View {
            VStack(spacing: 0) {
                Text("Select Voice")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)

                if isLoading {
                    loadingView
                } else {
                    voiceListView
                }

                Divider()
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                HStack {
                    Spacer()
                    Button("Done") {
                        ttsPreviewService.stopPlayback()
                        isPresented = false
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(colors.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(colors.accent.opacity(0.12))
                    )
                }
            }
            .padding(24)
            .frame(minWidth: 420, minHeight: 400)
            .background(colors.background)
            .task {
                await loadVoices()
            }
        }
    #endif

    // MARK: - iOS Content

    private var iOSContent: some View {
        NavigationStack {
            Group {
                if isLoading {
                    loadingView
                } else {
                    List {
                        Section {
                            ForEach(voices) { voice in
                                voiceRow(voice)
                                    .listRowBackground(colors.cardBackground)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(colors.background.ignoresSafeArea())
            .navigationTitle("Select Voice")
            #if os(iOS)
                .listStyle(.insetGrouped)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            ttsPreviewService.stopPlayback()
                            isPresented = false
                        }
                    }
                }
        }
        .tint(colors.accent)
        .task {
            await loadVoices()
        }
    }

    // MARK: - Shared Components

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading voices...")
                .font(.system(size: 14))
                .foregroundColor(colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var voiceListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(voices) { voice in
                    voiceRowCard(voice)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func voiceRowCard(_ voice: VoiceConfig) -> some View {
        voiceRow(voice)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(colors.cardBackground)
            )
    }

    private func voiceRow(_ voice: VoiceConfig) -> some View {
        let isSelected = preferences.selectedVoiceID == voice.id
        let isPlaying = ttsPreviewService.isPlaying && ttsPreviewService.currentVoiceID == voice.id

        return HStack(spacing: 12) {
            Button {
                selectVoice(voice)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.name)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(colors.textPrimary)
                        if voice.isDefault {
                            Text("Default")
                                .font(.system(size: 12))
                                .foregroundColor(colors.textSecondary)
                        }
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(colors.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    await playPreview(voice)
                }
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .foregroundColor(isPlaying ? .red : colors.accent)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(isPlaying ? Color.red.opacity(0.15) : colors.accent.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func loadVoices() async {
        isLoading = true
        voices = VoiceConfig.defaultVoices
        isLoading = false
    }

    private func selectVoice(_ voice: VoiceConfig) {
        preferences.setSelectedVoiceID(voice.id)
    }

    @MainActor
    private func playPreview(_ voice: VoiceConfig) async {
        if ttsPreviewService.isPlaying && ttsPreviewService.currentVoiceID == voice.id {
            ttsPreviewService.stopPlayback()
        } else {
            await ttsPreviewService.playPreview(voiceID: voice.id)
        }
    }
}

#Preview {
    VoicePickerView(isPresented: .constant(true))
        .preferredColorScheme(.dark)
}
