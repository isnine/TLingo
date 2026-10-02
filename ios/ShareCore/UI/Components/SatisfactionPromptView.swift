//
//  SatisfactionPromptView.swift
//  TLingo
//
//  Created by Zander Wang on 2026/04/13.
//

import SwiftUI

struct SatisfactionPromptView: View {
    @Environment(\.colorScheme) private var colorScheme

    let colors: AppColorPalette
    let onSatisfied: () -> Void
    let onFeedback: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 12) {
            Text("Was TLingo helpful today?")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(colors.textPrimary)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button {
                    onSatisfied()
                } label: {
                    Label("Love it", systemImage: "heart.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .tlingoGlassCapsule(
                            tint: colors.accent.opacity(0.34),
                            interactive: true,
                            fallbackTint: colors.accent,
                            fallbackStroke: .clear
                        )
                }
                .buttonStyle(.plain)

                Button {
                    onFeedback()
                } label: {
                    Label("Feedback", systemImage: "envelope")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .tlingoGlassCapsule(.chrome, interactive: true)
                }
                .buttonStyle(.plain)

                Button {
                    onDismiss()
                } label: {
                    Text("Later")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(colors.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .tlingoGlassCapsule(.control, interactive: true)
                }
                .buttonStyle(.plain)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .padding(16)
        .frame(maxWidth: 360)
        .background {
            Color.clear
                .tlingoGlassSurface(.panel, cornerRadius: TLingoRadius.large)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 14, x: 0, y: 8)
        }
    }
}
