//
//  DownloadLanguagesGuideView.swift
//  ShareCore
//

import SwiftUI

private struct DownloadLanguagesGuideContent {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let steps: [LocalizedStringKey]
}

struct DownloadLanguagesGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    guide
                }
                .padding(24)
            }
            .background(colors.background.ignoresSafeArea())
            .navigationTitle("Download More Languages")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var guideContent: DownloadLanguagesGuideContent {
        #if os(iOS)
            return DownloadLanguagesGuideContent(
                icon: "iphone",
                title: "On iPhone / iPad",
                subtitle: "Go to Settings to download language packs for offline use.",
                steps: [
                    "Open the **Settings** app",
                    "Tap **Apps** → **Translate**",
                    "Tap **Languages**",
                    "Toggle on the languages you want to use offline",
                ]
            )
        #else
            return DownloadLanguagesGuideContent(
                icon: "laptopcomputer",
                title: "On Mac",
                subtitle: "Download language packs from System Settings.",
                steps: [
                    "Open **System Settings**",
                    "Click **General** → **Language & Region**",
                    "Scroll down to **Translation Languages**",
                    "Click **+** to add the languages you need",
                ]
            )
        #endif
    }

    private var guide: some View {
        let content = guideContent
        return VStack(alignment: .leading, spacing: 20) {
            guideHeader(icon: content.icon, title: content.title, subtitle: content.subtitle)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(content.steps.enumerated()), id: \.offset) { index, text in
                    guideStep(number: index + 1, text: text)
                }
            }

            openSettingsButton
        }
    }

    private var openSettingsButton: some View {
        Button {
            #if os(iOS)
                let settingsURL = URL(string: UIApplication.openSettingsURLString)
            #else
                let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings")
            #endif
            if let settingsURL {
                openURL(settingsURL)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 14, weight: .semibold))
                Text("Open Settings")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(colors.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func guideHeader(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(colors.accent)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(colors.textSecondary)
            }
        }
    }

    private func guideStep(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(colors.accent)
                .clipShape(Circle())

            Text(text)
                .font(.system(size: 15))
                .foregroundColor(colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
