//
//  OnboardingStep1TextSelection.swift
//  TLingo
//
//  Step 1 of first-launch onboarding: enable text selection translation.
//

#if os(macOS) && DIRECT_DISTRIBUTION
    import ShareCore
    import SwiftUI

    struct OnboardingStep1TextSelection: View {
        @ObservedObject var permissionManager: AccessibilityPermissionManager
        let colors: AppColorPalette

        var body: some View {
            VStack(spacing: 16) {
                OnboardingStepHeader(
                    systemImage: "hand.point.up.left.and.text",
                    iconColor: colors.accent,
                    title: "Translate or polish text without switching apps",
                    subtitle: "Select text in any app to translate or polish it.",
                    colors: colors
                )

                HStack(spacing: 12) {
                    Image(systemName: permissionManager.isAccessibilityGranted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundColor(permissionManager.isAccessibilityGranted ? .green : colors.textSecondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(colors.textPrimary)
                        Text(permissionManager
                            .isAccessibilityGranted ? String(localized: "Granted") :
                            String(localized: "Required to detect text selections"))
                            .font(.system(size: 12))
                            .foregroundColor(permissionManager.isAccessibilityGranted ? .green : colors.textSecondary)
                    }

                    Spacer()
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colors.cardBackground)
                )

                if permissionManager.showsReplacementHint {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        Text("Already listed? Remove the old entry with −, then drag TLingo in again.")
                            .font(.system(size: 12))
                            .foregroundColor(colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.orange.opacity(0.1))
                    )
                }

                Spacer(minLength: 0)
            }
            .onAppear { permissionManager.startPolling() }
            .onDisappear { permissionManager.stopPolling() }
        }
    }
#endif
