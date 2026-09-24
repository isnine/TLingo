//
//  ActionDetailView.swift
//  TLingo
//
//  Created by Codex on 2025/10/23.
//

import ShareCore
import SwiftUI

struct ActionDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var configurationStore: AppConfigurationStore

    private let actionID: UUID
    private let isNewAction: Bool
    private let isReadOnly: Bool
    @State private var name: String
    @State private var prompt: String
    @State private var outputType: OutputType

    // Validation error state
    @State private var showValidationError = false
    @State private var validationErrorMessage = ""

    // Collapsible section state
    @State private var isOutputTypeExpanded: Bool

    // Delete confirmation state
    @State private var showDeleteConfirmation = false

    private let isAIGenerated: Bool

    init(
        action: ActionConfig?,
        configurationStore: AppConfigurationStore,
        isReadOnly: Bool = false,
        isAIGenerated: Bool = false
    ) {
        _configurationStore = ObservedObject(wrappedValue: configurationStore)
        self.isReadOnly = isReadOnly
        self.isAIGenerated = isAIGenerated
        _isOutputTypeExpanded = State(initialValue: isAIGenerated)

        if let action = action {
            actionID = action.id
            isNewAction = false
            _name = State(initialValue: isReadOnly ? action.displayName : action.name)
            _prompt = State(initialValue: action.prompt)
            _outputType = State(initialValue: action.outputType)
        } else {
            actionID = UUID()
            isNewAction = true
            _name = State(initialValue: "")
            _prompt = State(initialValue: #"Translate: "{text}" to {targetLanguage} with tone: fluent"#)
            _outputType = State(initialValue: .plain)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    basicInfoSection
                    promptSection
                    optionsSection

                    if isAIGenerated {
                        aiGeneratedBanner
                    }

                    if !isNewAction && !isReadOnly {
                        deleteSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
        }
        .background(colors.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .alert("Validation Failed", isPresented: $showValidationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationErrorMessage)
        }
        .alert("Delete Action", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteAction()
            }
        } message: {
            Text("Are you sure you want to delete this action? This cannot be undone.")
        }
    }

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    private var headerBar: some View {
        HStack(spacing: 16) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 16, weight: .medium))
                }
                .foregroundColor(colors.textPrimary)
            }
            .buttonStyle(.plain)

            Spacer()

            if !isReadOnly {
                Button {
                    saveAction()
                } label: {
                    Text("Save")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(colors.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(colors.background.opacity(0.98))
    }

    private var basicInfoSection: some View {
        section(title: "Basic Info") {
            labeledField(title: "Action Name", text: $name)
        }
        .disabled(isReadOnly)
    }

    private var promptSection: some View {
        section(
            title: "Prompt Template",
            subtitle: "Use {text}, {targetLanguage}, {sourceLanguage}, and {appLanguage} as placeholders"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HighlightingPromptEditor(
                    text: $prompt,
                    textColor: colors.textPrimary,
                    highlightColor: colors.accent,
                    isEditable: !isReadOnly
                )
                .frame(minHeight: 160)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(colors.inputBackground)
                )
            }
        }
        .disabled(isReadOnly)
    }

    private var outputTypeSummary: String {
        switch outputType {
        case .plain: return String(localized: "Plain Text")
        case .diff: return String(localized: "Show Diff")
        case .sentencePairs: return String(localized: "Translator Sentence Pairs")
        case .grammarCheck: return String(localized: "Grammar Check")
        case .translate: return String(localized: "Translate")
        }
    }

    private var optionsSection: some View {
        collapsibleSection(
            title: "Output Type",
            summary: outputTypeSummary,
            isExpanded: $isOutputTypeExpanded
        ) {
            VStack(spacing: 12) {
                outputTypeRow(
                    type: .plain,
                    title: "Plain Text",
                    description: "Standard text output without special formatting"
                )
                outputTypeRow(
                    type: .diff,
                    title: "Show Diff",
                    description: "Highlights differences between original and AI output"
                )
                outputTypeRow(
                    type: .sentencePairs,
                    title: "Translator Sentence Pairs",
                    description: "Display original and translation side by side, supports Apple Translate"
                )
                outputTypeRow(
                    type: .grammarCheck,
                    title: "Grammar Check",
                    description: "Show revised text with grammar explanations"
                )
                outputTypeRow(
                    type: .translate,
                    title: "Translate",
                    description: "Translation output — enables Apple Translate support"
                )
            }
        }
        .disabled(isReadOnly)
    }

    private var aiGeneratedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
            Text("Generated by AI — please review before saving", comment: "AI-generated action banner")
                .font(.system(size: 13))
        }
        .foregroundColor(colors.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colors.accent.opacity(0.08))
        )
    }

    private func outputTypeRow(
        type: OutputType,
        title: LocalizedStringKey,
        description: LocalizedStringKey
    ) -> some View {
        let isSelected = outputType == type
        return Button {
            outputType = type
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundColor(colors.textSecondary)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? colors.accent : colors.textSecondary.opacity(0.6))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectionRowBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func selectionRowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? colors.accent : .clear, lineWidth: 2)
            )
    }

    private var deleteSection: some View {
        section(title: "Danger Zone") {
            Button {
                showDeleteConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Delete Action")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.red.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func section(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(colors.textPrimary)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(colors.textSecondary)
            }

            content()
        }
    }

    @ViewBuilder
    private func collapsibleSection(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        summary: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(colors.textPrimary)

                    Spacer()

                    if !isExpanded.wrappedValue {
                        Text(summary)
                            .font(.system(size: 14))
                            .foregroundColor(colors.textSecondary)
                            .lineLimit(1)
                    }

                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(colors.textSecondary.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(colors.textSecondary)
                }

                content()
            }
        }
    }

    private func labeledField(title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(colors.textSecondary)

            TextField(String(), text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(colors.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(colors.inputBackground)
                )
        }
    }
}

private extension ActionDetailView {
    private func saveAction() {
        guard !isReadOnly else { return }

        let updated = ActionConfig(
            id: actionID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            outputType: outputType
        )

        var actions = configurationStore.customActions

        // Find and update the action
        if let index = actions.firstIndex(where: { $0.id == actionID }) {
            actions[index] = updated
        } else {
            // New action
            actions.append(updated)
        }

        switch configurationStore.updateCustomActions(actions) {
        case let .success(result) where result?.hasErrors == true:
            validationErrorMessage = result?.errors.map(\.message).joined(separator: "\n") ?? ""
            showValidationError = true
        case .success:
            dismiss()
        case let .failure(error):
            validationErrorMessage = error.localizedDescription
            showValidationError = true
        }
    }

    private func deleteAction() {
        guard !isReadOnly else { return }

        var actions = configurationStore.customActions
        actions.removeAll { $0.id == actionID }

        switch configurationStore.updateCustomActions(actions) {
        case let .success(result) where result?.hasErrors == true:
            validationErrorMessage = result?.errors.map(\.message).joined(separator: "\n") ?? ""
            showValidationError = true
        case .success:
            dismiss()
        case let .failure(error):
            validationErrorMessage = error.localizedDescription
            showValidationError = true
        }
    }
}

#Preview {
    NavigationStack {
        ActionDetailView(
            action: AppConfigurationStore.shared.actions.first!,
            configurationStore: AppConfigurationStore.shared
        )
        .preferredColorScheme(.dark)
    }
}
