//
//  WhatsNewView.swift
//  ShareCore
//

import SwiftUI

/// Sheet listing what changed since the version the user last opened.
public struct WhatsNewView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    let summary: WhatsNewSummary
    let onDone: () -> Void
    let onWish: () -> Void

    public init(summary: WhatsNewSummary, onDone: @escaping () -> Void, onWish: @escaping () -> Void) {
        self.summary = summary
        self.onDone = onDone
        self.onWish = onWish
    }

    private var colors: AppColors.Palette {
        AppColors.palette(for: colorScheme)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(ReleaseNotes.Item.Kind.allCases, id: \.self) { kind in
                            let items = summary.items.filter { $0.kind == kind }
                            if !items.isEmpty {
                                section(kind, items: items)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actions
            }
        }
        .background(colors.cardBackground)
        #if os(macOS)
            .frame(width: 420, height: 560)
        #else
            // Sit the actions on the sheet's rounded bottom edge rather than above the home-indicator inset.
            .ignoresSafeArea(.container, edges: .bottom)
        #endif
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.45)) {
                hasAppeared = true
            }
        }
        #if os(iOS)
        .sensoryFeedback(.success, trigger: hasAppeared)
        #endif
    }

    private var header: some View {
        VStack(spacing: 8) {
            hero
            if summary.missedVersionCount > 1 {
                Text("Welcome Back", tableName: WhatsNew.table, bundle: WhatsNew.bundle)
                    .font(.system(size: 26, weight: .bold))
                Text(
                    "TLingo got \(summary.missedVersionCount) updates while you were away",
                    tableName: WhatsNew.table,
                    bundle: WhatsNew.bundle
                )
                .font(.subheadline)
                .foregroundStyle(colors.textSecondary)
                versionPill(Text(verbatim: "\(summary.previousVersion) → \(summary.version)"))
            } else {
                Text("TLingo Has Been Updated", tableName: WhatsNew.table, bundle: WhatsNew.bundle)
                    .font(.system(size: 26, weight: .bold))
                versionPill(Text("Version \(summary.version)", tableName: WhatsNew.table, bundle: WhatsNew.bundle))
            }
        }
        .foregroundStyle(colors.textPrimary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// The accent badge with confetti in the other accent themes' colours.
    private var hero: some View {
        ZStack {
            confetti(.orange, size: CGSize(width: 9, height: 9), at: CGPoint(x: -70, y: -18))
            confetti(.teal, size: CGSize(width: 6, height: 14), at: CGPoint(x: -47, y: 23), angle: 28)
            confetti(.purple, size: CGSize(width: 6, height: 6), at: CGPoint(x: -39, y: -33))
            confetti(.pink, size: CGSize(width: 6, height: 14), at: CGPoint(x: 69, y: -21), angle: -24)
            confetti(.green, size: CGSize(width: 9, height: 9), at: CGPoint(x: 50, y: 23))
            confetti(.orange, size: CGSize(width: 5, height: 5), at: CGPoint(x: 37, y: -38))

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(colors.accentFill)
                .frame(width: 72, height: 72)
                .shadow(color: colors.accentFill.opacity(0.28), radius: 10, y: 8)
                .overlay {
                    Image(systemName: "sparkles")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(colors.onAccent)
                }
                .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.8)
        }
        .frame(width: 168, height: 84)
        .accessibilityHidden(true)
    }

    private func confetti(
        _ theme: AccentTheme,
        size: CGSize,
        at offset: CGPoint,
        angle: Double = 0
    ) -> some View {
        Capsule()
            .fill(theme.color)
            .frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(angle))
            .offset(
                x: hasAppeared || reduceMotion ? offset.x : offset.x * 0.4,
                y: hasAppeared || reduceMotion ? offset.y : offset.y * 0.4
            )
            .opacity(hasAppeared ? 1 : 0)
    }

    private func versionPill(_ text: Text) -> some View {
        text
            .font(.caption.weight(.semibold))
            .foregroundStyle(colors.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(colors.accent.opacity(0.1), in: Capsule())
            .padding(.top, 4)
    }

    private func section(_ kind: ReleaseNotes.Item.Kind, items: [ReleaseNotes.Item]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            kind.title
                .font(.footnote.weight(.semibold))
                .foregroundStyle(colors.textSecondary)
            ForEach(items, id: \.text) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(kind.tint(colors))
                        .frame(width: 30, height: 30)
                        .background(
                            kind.tint(colors).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .accessibilityHidden(true)
                    Text(item.localizedText)
                        .font(.body)
                        .foregroundStyle(colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button(action: onWish) {
                Label {
                    Text("Wish for a Feature", tableName: WhatsNew.table, bundle: WhatsNew.bundle)
                } icon: {
                    Image(systemName: "wand.and.sparkles")
                }
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(colors.accent)
            .accessibilityIdentifier("whats_new_wish_button")

            Button(action: onDone) {
                Text("Got It", tableName: WhatsNew.table, bundle: WhatsNew.bundle)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(colors.accentFill)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("whats_new_done_button")
        }
        .buttonBorderShape(.capsule)
        .controlSize(.extraLarge)
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .background {
            LinearGradient(
                stops: [
                    .init(color: colors.cardBackground.opacity(0), location: 0),
                    .init(color: colors.cardBackground, location: 0.3),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

private extension ReleaseNotes.Item.Kind {
    var title: Text {
        switch self {
        case .added: Text("New", tableName: WhatsNew.table, bundle: WhatsNew.bundle)
        case .improved: Text("Improved", tableName: WhatsNew.table, bundle: WhatsNew.bundle)
        case .fixed: Text("Fixed", tableName: WhatsNew.table, bundle: WhatsNew.bundle)
        }
    }

    var systemImage: String {
        switch self {
        case .added: "plus"
        case .improved: "arrow.up"
        case .fixed: "checkmark"
        }
    }

    func tint(_ colors: AppColors.Palette) -> Color {
        switch self {
        case .added: AccentTheme.green.strongColor
        case .improved: colors.accent
        case .fixed: AccentTheme.orange.strongColor
        }
    }
}
