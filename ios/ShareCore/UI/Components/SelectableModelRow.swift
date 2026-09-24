//
//  SelectableModelRow.swift
//  ShareCore
//

import SwiftUI

public struct SelectableModelRow: View {
    public enum Style {
        case regular
        case compact
    }

    public struct Badge {
        let title: String
        let color: Color

        public init(_ title: String, color: Color) {
            self.title = title
            self.color = color
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private let model: ModelConfig
    private let isSelected: Bool
    private let isLocked: Bool
    private let isDimmed: Bool
    private let subtitle: String?
    private let style: Style
    private let additionalBadges: [Badge]
    private let showsDefaultBadge: Bool
    private let showsPremiumCrown: Bool
    private let showsModelTags: Bool
    private let action: () -> Void

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    public init(
        model: ModelConfig,
        isSelected: Bool,
        isLocked: Bool = false,
        isDimmed: Bool = false,
        subtitle: String? = nil,
        style: Style = .regular,
        additionalBadges: [Badge] = [],
        showsDefaultBadge: Bool = true,
        showsPremiumCrown: Bool = true,
        showsModelTags: Bool = true,
        action: @escaping () -> Void
    ) {
        self.model = model
        self.isSelected = isSelected
        self.isLocked = isLocked
        self.isDimmed = isDimmed
        self.subtitle = subtitle
        self.style = style
        self.additionalBadges = additionalBadges
        self.showsDefaultBadge = showsDefaultBadge
        self.showsPremiumCrown = showsPremiumCrown
        self.showsModelTags = showsModelTags
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                selectionIcon
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    titleLine
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: subtitleFontSize))
                            .foregroundColor(colors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, verticalPadding)
            .contentShape(Rectangle())
            .opacity(isDimmed ? 0.4 : 1)
        }
        .buttonStyle(.plain)
    }

    private var selectionIcon: some View {
        Image(systemName: isLocked ? "lock.fill" : (isSelected ? "checkmark.circle.fill" : "circle"))
            .font(.system(size: isLocked ? 18 : 22))
            .foregroundColor(iconColor)
    }

    private var titleLine: some View {
        ModelTagFlowLayout(spacing: titleSpacing) {
            Text(model.displayName)
                .font(.system(size: titleFontSize, weight: .semibold))
                .foregroundColor(titleColor)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(additionalBadges.enumerated()), id: \.offset) { _, badge in
                tag(badge.title, color: badge.color)
            }

            if showsDefaultBadge, model.isDefault {
                tag(String(localized: "Default"), color: colors.accent)
            }

            if showsPremiumCrown, model.isPremium {
                Image(systemName: "crown.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }

            if showsModelTags {
                ForEach(Array(model.tags.enumerated()), id: \.offset) { _, tag in
                    let tagStyle = model.tagStyles[tag]
                    self.tag(
                        tag.uppercased(),
                        color: tagColor(tagStyle?.textColor) ?? .green,
                        background: tagColor(tagStyle?.backgroundColor)
                    )
                }
            }
        }
    }

    private var iconColor: Color {
        if isSelected {
            return colors.accent
        }
        return colors.textSecondary.opacity(isLocked ? 0.45 : 0.4)
    }

    private var titleColor: Color {
        isLocked || isDimmed ? colors.textSecondary : colors.textPrimary
    }

    private var titleFontSize: CGFloat {
        style == .compact ? 14 : 15
    }

    private var subtitleFontSize: CGFloat {
        style == .compact ? 12 : 13
    }

    private var titleSpacing: CGFloat {
        style == .compact ? 6 : 8
    }

    private var verticalPadding: CGFloat {
        style == .compact ? 13 : 14
    }

    private func tagColor(_ hex: String?) -> Color? {
        guard let hex, hex.hasPrefix("#"), hex.count == 7,
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255,
            opacity: 1
        )
    }

    private func tag(_ title: String, color: Color, background: Color? = nil) -> some View {
        Text(title)
            .font(.system(size: style == .compact ? 10 : 11, weight: style == .compact ? .semibold : .medium))
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background ?? color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ModelTagFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = result.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let limit = max(0, width ?? .infinity)
        var frames: [CGRect] = []
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, limit), height: nil))
            if offsetX > 0, offsetX + size.width > limit {
                offsetX = 0
                offsetY += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: offsetX, y: offsetY), size: size))
            usedWidth = max(usedWidth, offsetX + size.width)
            rowHeight = max(rowHeight, size.height)
            offsetX += size.width + spacing
        }
        return (CGSize(width: usedWidth, height: offsetY + rowHeight), frames)
    }
}

#Preview("Model tags - narrow") {
    VStack(spacing: 0) {
        SelectableModelRow(
            model: ModelConfig(
                id: "gemini",
                displayName: "Gemini 3.8 Flash",
                isPremium: true,
                tags: ["Latest - Sep 2", "Recommended"],
                tagStyles: ["Recommended": ModelTagStyle(textColor: "#166534", backgroundColor: "#DCFCE7")]
            ),
            isSelected: true
        ) {}
        SelectableModelRow(
            model: ModelConfig(
                id: "sample-model",
                displayName: "Sample Model",
                isPremium: true,
                tags: ["Experimental", "Unstable", "A much longer tag that wraps within the available width"],
                tagStyles: ["Unstable": ModelTagStyle(textColor: "#991B1B", backgroundColor: "#FEE2E2")]
            ),
            isSelected: false, style: .compact
        ) {}
    }
    .frame(width: 280)
    .padding(.vertical)
}
