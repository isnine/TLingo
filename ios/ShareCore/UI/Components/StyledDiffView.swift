import SwiftUI

struct StyledDiffView: View {
    let diff: TextDiffBuilder.Presentation

    @Environment(\.colorScheme) private var colorScheme

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if diff.hasRemovals {
                diffBlock(
                    title: "Original",
                    systemImage: "minus",
                    segments: diff.originalSegments,
                    tint: colors.textSecondary
                )
            }

            if diff.hasAdditions || !diff.hasRemovals {
                diffBlock(
                    title: "Revised",
                    systemImage: "plus",
                    segments: diff.revisedSegments,
                    tint: colors.accent
                )
            }
        }
    }

    private func diffBlock(
        title: LocalizedStringKey,
        systemImage: String,
        segments: [TextDiffBuilder.Segment],
        tint: Color
    ) -> some View {
        let plainText = segments.map(\.text).joined()
        let isRTL = BidiText.isRTLText(plainText)
        let text = TextDiffBuilder.attributedString(
            for: segments,
            palette: colors,
            colorScheme: colorScheme
        )

        return HStack(spacing: 0) {
            Rectangle()
                .fill(tint.opacity(colorScheme == .dark ? 0.7 : 0.5))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(colors.textSecondary)

                Text(text)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
                    .contentDirectionAware(plainText)
            }
            .padding(.leading, 10)
            .padding(.vertical, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
