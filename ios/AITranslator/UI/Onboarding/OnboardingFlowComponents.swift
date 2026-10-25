//
//  OnboardingFlowComponents.swift
//  TLingo
//
//  Buttons, progress dots and card surface shared by the scenario picker and the
//  Realtime onboarding. Sizes match `DefaultTranslationOnboardingView` so the
//  pages read as one flow.
//

#if os(iOS)
    import ShareCore
    import SwiftUI

    enum OnboardingMetrics {
        static let horizontalPadding: CGFloat = 20
        static let primaryButtonHeight: CGFloat = 50
        static let secondaryButtonHeight: CGFloat = 42
        static let buttonRadius: CGFloat = 12
        static let cardRadius: CGFloat = 12
        static let footerSpacing: CGFloat = 10
        static let stepTransition: Double = 0.2
    }

    struct OnboardingPrimaryButton: View {
        let title: LocalizedStringKey
        let colors: AppColorPalette
        var isDisabled = false
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(colors.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: OnboardingMetrics.primaryButtonHeight)
                    .background(
                        RoundedRectangle(cornerRadius: OnboardingMetrics.buttonRadius, style: .continuous)
                            .fill(isDisabled ? colors.textSecondary.opacity(0.28) : colors.accentFill)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
    }

    struct OnboardingSecondaryButton: View {
        let title: LocalizedStringKey
        let colors: AppColorPalette
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: OnboardingMetrics.secondaryButtonHeight)
            }
            .buttonStyle(.plain)
        }
    }

    /// Non-interactive progress dots; the active step is a wider capsule.
    struct OnboardingProgressDots: View {
        let total: Int
        let index: Int
        let colors: AppColorPalette

        var body: some View {
            HStack(spacing: 8) {
                ForEach(0 ..< total, id: \.self) { position in
                    Capsule()
                        .fill(position == index ? colors.accent : colors.textSecondary.opacity(0.25))
                        .frame(width: position == index ? 20 : 7, height: 7)
                        .animation(.easeInOut(duration: OnboardingMetrics.stepTransition), value: index)
                }
            }
            .frame(minHeight: 23)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Step \(index + 1) of \(total)"))
        }
    }

    extension View {
        func onboardingCardBackground(colors: AppColorPalette) -> some View {
            background(
                RoundedRectangle(cornerRadius: OnboardingMetrics.cardRadius, style: .continuous)
                    .fill(colors.cardBackground)
            )
        }
    }
#endif
