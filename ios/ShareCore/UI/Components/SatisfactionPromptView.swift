//
//  SatisfactionPromptView.swift
//  TLingo
//
//  Created by Zander Wang on 2026/04/13.
//

import SwiftUI

struct SatisfactionPromptView: View {
    enum Style {
        case toast
        case resultCard
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let colors: AppColorPalette
    var style: Style = .toast
    let onSatisfied: () -> Void
    let onFeedback: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        switch style {
        case .toast:
            Group {
                if #available(iOS 26.0, macOS 26.0, *) {
                    GlassEffectContainer(spacing: 10) {
                        toastContent
                    }
                } else {
                    toastContent
                }
            }
        case .resultCard:
            resultCardContent
        }
    }

    private var toastContent: some View {
        VStack(spacing: 12) {
            Text("Was TLingo helpful today?")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(colors.textPrimary)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button(action: onSatisfied) {
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

                Button(action: onFeedback) {
                    Label("Feedback", systemImage: "envelope")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .tlingoGlassCapsule(.chrome, interactive: true)
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
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

    private var resultCardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(colors.accent)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Was TLingo helpful today?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(colors.textPrimary)

                    Text("Share quick feedback so the translation experience keeps improving.")
                        .font(.system(size: 13))
                        .foregroundColor(colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(colors.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(colors.inputBackground.opacity(colorScheme == .dark ? 0.70 : 0.85))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }

            HStack(spacing: 10) {
                Button(action: onSatisfied) {
                    Label("Love it", systemImage: "heart.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(colors.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(colors.accentFill)
                        )
                }
                .buttonStyle(.plain)

                Button(action: onFeedback) {
                    Label("Feedback", systemImage: "envelope")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(colors.inputBackground.opacity(colorScheme == .dark ? 0.70 : 0.86))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(colors.divider, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text("Later")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.88)
        }
        .padding(TLingoSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TLingoRadius.medium, style: .continuous)
                .fill(colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TLingoRadius.medium, style: .continuous)
                .stroke(colors.divider, lineWidth: 1)
        )
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
    }
}
