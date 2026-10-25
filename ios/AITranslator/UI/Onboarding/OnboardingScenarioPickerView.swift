//
//  OnboardingScenarioPickerView.swift
//  TLingo
//
//  First page of onboarding: the user picks every scenario they want to
//  translate in. The picks decide which setup flows run (see `OnboardingRoute`).
//

#if os(iOS)
    import ShareCore
    import SwiftUI

    struct OnboardingScenarioPickerView: View {
        @Environment(\.colorScheme) private var colorScheme
        @ObservedObject private var preferences = AppPreferences.shared
        @State private var selection: Set<OnboardingScenario>

        let onContinue: (Set<OnboardingScenario>) -> Void
        let onSkip: () -> Void

        /// - Parameter initialSelection: Restores the picks when the user comes back from a later page.
        init(
            initialSelection: Set<OnboardingScenario> = [],
            onContinue: @escaping (Set<OnboardingScenario>) -> Void,
            onSkip: @escaping () -> Void
        ) {
            _selection = State(initialValue: initialSelection)
            self.onContinue = onContinue
            self.onSkip = onSkip
        }

        private var colors: AppColorPalette {
            AppColors.Palette(colorScheme: colorScheme, accentTheme: preferences.accentTheme)
        }

        var body: some View {
            ZStack {
                colors.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("What will you translate?")
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundStyle(colors.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Pick everything that applies. TLingo sets up each one with you.")
                                    .font(.system(size: 15))
                                    .foregroundStyle(colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            VStack(spacing: 12) {
                                ForEach(OnboardingScenario.allCases) { scenario in
                                    scenarioCard(scenario)
                                }
                            }
                        }
                        .padding(.top, 44)
                        .padding(.horizontal, OnboardingMetrics.horizontalPadding)
                        .padding(.bottom, 20)
                    }

                    VStack(spacing: OnboardingMetrics.footerSpacing) {
                        OnboardingPrimaryButton(title: "Continue", colors: colors, isDisabled: selection.isEmpty) {
                            onContinue(selection)
                        }
                        .accessibilityIdentifier("onboarding_scenarios_continue")

                        OnboardingSecondaryButton(title: "Skip for now", colors: colors, action: onSkip)
                            .accessibilityIdentifier("onboarding_scenarios_skip")
                    }
                    .padding(.horizontal, OnboardingMetrics.horizontalPadding)
                    .padding(.bottom, 8)
                }
            }
            .tint(colors.accent)
        }

        private func scenarioCard(_ scenario: OnboardingScenario) -> some View {
            let isSelected = selection.contains(scenario)
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

            return Button {
                if isSelected {
                    selection.remove(scenario)
                } else {
                    selection.insert(scenario)
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: scenario.systemImage)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(colors.accent)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(colors.chipSecondaryBackground)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(scenario.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(colors.textPrimary)
                        Text(scenario.subtitle)
                            .font(.system(size: 14))
                            .foregroundStyle(colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundStyle(isSelected ? colors.accentFill : colors.textSecondary.opacity(0.5))
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                .background(shape.fill(colors.cardBackground))
                .overlay(
                    shape.strokeBorder(isSelected ? colors.accentFill : colors.divider, lineWidth: 2)
                )
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("onboarding_scenario_\(scenario.rawValue)")
        }
    }

    private extension OnboardingScenario {
        var systemImage: String {
            switch self {
            case .words: "character.book.closed"
            case .liveConversations: "mic.fill"
            case .showsAndVideos: "play.rectangle"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .words: "Words and selected text"
            case .liveConversations: "Live conversations"
            case .showsAndVideos: "Shows and videos"
            }
        }

        var subtitle: LocalizedStringKey {
            switch self {
            case .words: "Select text in any app and translate it from the text menu."
            case .liveConversations: "Speak or listen and read bilingual captions as they happen."
            case .showsAndVideos: "Get captions for audio playing on your iPhone."
            }
        }
    }
#endif
