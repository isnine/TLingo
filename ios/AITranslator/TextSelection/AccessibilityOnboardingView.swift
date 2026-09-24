//
//  AccessibilityOnboardingView.swift
//  TLingo
//
//  First-enable onboarding sheet for Accessibility permission.
//

#if os(macOS)
    import ShareCore
    import SwiftUI

    struct AccessibilityOnboardingView: View {
        @ObservedObject var permissionManager: AccessibilityPermissionManager
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.dismiss) private var dismiss

        let onPermissionGranted: () -> Void

        private var colors: AppColorPalette {
            AppColors.Palette(colorScheme: colorScheme, accentTheme: AppPreferences.shared.accentTheme)
        }

        var body: some View {
            VStack(spacing: 24) {
                // Icon
                Image(systemName: "hand.point.up.left.and.text")
                    .font(.system(size: 48))
                    .foregroundStyle(colors.accent)
                    .padding(.top, 20)

                // Title
                VStack(spacing: 8) {
                    Text("Text Selection Translation")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(colors.textPrimary)

                    Text(
                        "Select text in any app to instantly translate it. TLingo needs Accessibility permission to detect your text selections."
                    )
                    .font(.system(size: 14))
                    .foregroundColor(colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                }

                // Permission status
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
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colors.cardBackground)
                )

                Spacer()

                // Actions
                if permissionManager.isAccessibilityGranted {
                    Button {
                        onPermissionGranted()
                        dismiss()
                    } label: {
                        Text("Enable Text Selection Translation")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    VStack(spacing: 8) {
                        Button {
                            permissionManager.openAccessibilitySettings()
                        } label: {
                            Text("Open System Settings")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(colors.accent)
                                )
                        }
                        .buttonStyle(.plain)

                        Button {
                            dismiss()
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 13))
                                .foregroundColor(colors.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
            .frame(width: 380, height: 400)
            .background(colors.background)
            .onAppear { permissionManager.startPolling() }
            .onDisappear {
                permissionManager.stopPolling()
            }
        }
    }
#endif
