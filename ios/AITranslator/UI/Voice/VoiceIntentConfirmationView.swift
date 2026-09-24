//
//  VoiceIntentConfirmationView.swift
//  TLingo
//

import ShareCore
import SwiftUI

struct VoiceIntentConfirmationView: View {
    @Environment(\.colorScheme) private var colorScheme

    let transcript: String
    let onActionSelected: (ActionConfig) -> Void
    let onCancel: () -> Void

    @State private var options: [VoiceActionService.VoiceActionOption] = []
    @State private var allowCustomInput = false
    @State private var selectedOptionID: UUID?
    @State private var customText: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isRetrying = false

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerSection

            if isLoading {
                loadingSection
            } else if let errorMessage {
                errorSection(message: errorMessage)
            } else {
                optionsSection
                confirmButton
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(colors.background.ignoresSafeArea())
        .presentationBackground(colors.background)
        .task {
            await fetchOptions()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("I understand you want:", comment: "AI intent confirmation header")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(colors.textPrimary)
            Text(transcript)
                .font(.system(size: 14))
                .foregroundColor(colors.textSecondary)
                .lineLimit(3)
        }
    }

    private var loadingSection: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Generating options...", comment: "Loading AI options")
                .font(.system(size: 14))
                .foregroundColor(colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorSection(message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(colors.error)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button {
                    Task { await fetchOptions() }
                } label: {
                    Text("Retry", comment: "Retry fetching options")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(colors.accent)
                }
                .buttonStyle(.plain)

                Button {
                    onCancel()
                } label: {
                    Text("Create Manually", comment: "Fall back to manual creation")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var optionsSection: some View {
        VStack(spacing: 10) {
            Text("Choose the best match:", comment: "Option selection prompt")
                .font(.system(size: 14))
                .foregroundColor(colors.textSecondary)

            ForEach(options) { option in
                optionCard(option)
            }

            if allowCustomInput {
                customInputCard
            }
        }
    }

    private func optionCard(_ option: VoiceActionService.VoiceActionOption) -> some View {
        let isSelected = selectedOptionID == option.id
        return Button {
            selectedOptionID = option.id
            customText = ""
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                    Text(option.description)
                        .font(.system(size: 13))
                        .foregroundColor(colors.textSecondary)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? colors.accent : colors.textSecondary.opacity(0.5))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isSelected ? colors.accent : .clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var isCustomSelected: Bool {
        selectedOptionID == nil && !customText.isEmpty
    }

    private var customInputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                selectedOptionID = nil
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom Description", comment: "Custom input option title")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(colors.textPrimary)
                        Text("Describe what you want in your own words", comment: "Custom input option hint")
                            .font(.system(size: 13))
                            .foregroundColor(colors.textSecondary)
                    }

                    Spacer()

                    Image(systemName: isCustomSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundColor(isCustomSelected ? colors.accent : colors.textSecondary.opacity(0.5))
                }
            }
            .buttonStyle(.plain)

            if selectedOptionID == nil {
                TextField(
                    String(localized: "Enter your description...", comment: "Custom input placeholder"),
                    text: $customText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(colors.textPrimary)
                .lineLimit(3 ... 6)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colors.inputBackground)
                )
                .onChange(of: customText) {
                    if customText.count > 500 {
                        customText = String(customText.prefix(500))
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isCustomSelected ? colors.accent : .clear, lineWidth: 2)
                )
        )
    }

    private var confirmButton: some View {
        let canConfirm = selectedOptionID != nil
            || !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Button {
            if isCustomSelected {
                Task { await submitCustomInput() }
            } else if let selectedID = selectedOptionID,
                      let option = options.first(where: { $0.id == selectedID })
            {
                onActionSelected(option.actionConfig)
            }
        } label: {
            Group {
                if isRetrying {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Confirm and Generate", comment: "Confirm option selection")
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(
                    canConfirm
                        ? LinearGradient(
                            colors: [colors.accent, colors.accent.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        : LinearGradient(
                            colors: [Color.gray.opacity(0.4), Color.gray.opacity(0.3)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(!canConfirm || isRetrying)
    }

    // MARK: - API

    private func fetchOptions() async {
        isLoading = true
        errorMessage = nil

        let locale = Locale.current.language.languageCode?.identifier ?? "en"
        do {
            let result = try await VoiceActionService.shared.generateOptions(transcript: transcript, locale: locale)
            options = result.options
            allowCustomInput = result.allowCustomInput
            if let first = options.first {
                selectedOptionID = first.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func submitCustomInput() async {
        isRetrying = true
        let locale = Locale.current.language.languageCode?.identifier ?? "en"
        do {
            let result = try await VoiceActionService.shared.generateOptions(transcript: customText, locale: locale)
            if let firstOption = result.options.first {
                onActionSelected(firstOption.actionConfig)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isRetrying = false
    }
}
