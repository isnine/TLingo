//
//  OnboardingTrialSheet.swift
//  TLingo
//
//  Bottom sheet for the onboarding "try premium" step. Reuses
//  `CompactTranslationView` so the experience visually matches the system
//  Translation extension — same header, same action chip, same streaming
//  result card. The only twist is a HomeViewModel locked to selected
//  premium models in onboarding-trial mode, which routes the request
//  through `LLMService.perform(... onboardingTrial: true ...)` so the
//  Worker bypasses the premium entitlement check.
//

#if os(iOS) && !targetEnvironment(macCatalyst)
    import os
    import ShareCore
    import SwiftUI

    private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "OnboardingTrial")

    struct OnboardingTrialSheet: View {
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.dismiss) private var dismiss

        let inputText: String
        let trialModels: [ModelConfig]

        @StateObject private var viewModel: HomeViewModel
        @State private var hasStarted = false

        private var colors: AppColorPalette {
            AppColors.palette(for: colorScheme)
        }

        init(inputText: String, trialModels: [ModelConfig]) {
            self.inputText = inputText
            self.trialModels = trialModels
            _viewModel = StateObject(wrappedValue: HomeViewModel(
                supportsAppleTranslate: false,
                onboardingTrialModels: trialModels
            ))
        }

        var body: some View {
            NavigationStack {
                CompactTranslationView(
                    viewModel: viewModel,
                    onReplace: nil,
                    onConversation: nil
                )
                .navigationTitle("Translate with TLingo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(colors.textSecondary)
                        }
                        .accessibilityLabel("Close")
                    }
                }
            }
            .onAppear { startTrialIfNeeded() }
            .sheet(item: $viewModel.selectedDebugNetworkRecord) { record in
                NavigationStack {
                    NetworkRequestDetailView(record: record)
                }
            }
        }

        private func startTrialIfNeeded() {
            guard !hasStarted else { return }
            hasStarted = true
            let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                logger.debug("Trial sheet opened with empty input; skipping auto-trigger")
                return
            }
            viewModel.refreshConfiguration()
            viewModel.inputText = trimmed
            viewModel.performSelectedAction()
        }
    }
#endif
