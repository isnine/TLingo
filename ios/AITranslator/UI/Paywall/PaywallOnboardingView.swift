//
//  PaywallOnboardingView.swift
//  TLingo
//

import ShareCore
import SwiftUI

struct PaywallOnboardingView: View {
    let colors: AppColorPalette
    @State private var selection = 0

    private let pages: [PaywallOnboardingPage] = [
        PaywallOnboardingPage(
            icon: "sparkles",
            title: "Translate naturally with AI",
            subtitle: "Use premium models for translation that keeps tone, intent, and context.",
            bullets: [
                "GPT-powered translations",
                "More nuance than word-by-word output",
                "Compare multiple model results",
            ]
        ),
        PaywallOnboardingPage(
            icon: "waveform.and.mic",
            title: "Understand speech in realtime",
            subtitle: "Follow conversations, meetings, and videos with realtime captions and translation.",
            bullets: [
                "Live speech-to-text",
                "Translated captions",
                "Built for quick language switching",
            ]
        ),
        PaywallOnboardingPage(
            icon: "macbook.and.iphone",
            title: "One translator across devices",
            subtitle: "Unlock premium translation on iPhone and Mac with one subscription.",
            bullets: [
                "Premium models",
                "Custom theme colors",
                "Latest models as they launch",
            ]
        ),
    ]

    var body: some View {
        VStack(spacing: 18) {
            pager
                .frame(height: 300)

            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == selection ? colors.accent : colors.textSecondary.opacity(0.25))
                        .frame(width: index == selection ? 18 : 7, height: 7)
                        .animation(.easeInOut(duration: 0.2), value: selection)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var pager: some View {
        let content = TabView(selection: $selection) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                PaywallOnboardingPageView(page: page, colors: colors)
                    .tag(index)
            }
        }

        #if os(iOS)
            content
                .tabViewStyle(.page(indexDisplayMode: .never))
        #else
            content
        #endif
    }
}

private struct PaywallOnboardingPage {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let bullets: [LocalizedStringKey]
}

private struct PaywallOnboardingPageView: View {
    let page: PaywallOnboardingPage
    let colors: AppColorPalette

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: page.icon)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(colors.accent)
                .frame(width: 72, height: 72)
                .tlingoGlassCircle(
                    tint: colors.accent.opacity(0.12),
                    fallbackTint: colors.accent.opacity(0.08),
                    fallbackStroke: colors.accent.opacity(0.18)
                )
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(page.title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                Text(page.subtitle)
                    .font(.system(size: 15))
                    .foregroundColor(colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(page.bullets.indices, id: \.self) { index in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(colors.accent)
                            .accessibilityHidden(true)
                        Text(page.bullets[index])
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(colors.textPrimary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(PaywallCard(colors: colors))
        }
    }
}
