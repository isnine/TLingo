import ShareCore
import SwiftUI

#if os(macOS)
    /// White section cards on the app ground, matching the design canvas.
    /// The native grouped form cannot recolour its section fills, so macOS draws its own.
    struct CardFormStyle: FormStyle {
        let colors: AppColorPalette
        var maxWidth: CGFloat = 620
        var horizontalPadding: CGFloat = 20

        func makeBody(configuration: Configuration) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(sections: configuration.content) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            if !section.header.isEmpty {
                                section.header
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(colors.textSecondary)
                                    .padding(.horizontal, 12)
                            }
                            Group(subviews: section.content) { rows in
                                VStack(spacing: 0) {
                                    ForEach(rows) { row in
                                        if row.id != rows.first?.id {
                                            Divider()
                                                .padding(.leading, 12)
                                        }
                                        row
                                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                    }
                                }
                                .background(
                                    colors.cardBackground,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(colors.divider, lineWidth: 1)
                                }
                            }
                            if !section.footer.isEmpty {
                                section.footer
                                    .font(.system(size: 13))
                                    .foregroundStyle(colors.textSecondary)
                                    .padding(.horizontal, 12)
                            }
                        }
                    }
                }
                .labeledContentStyle(CardRowLabeledContentStyle())
                .toggleStyle(CardRowToggleStyle())
                .frame(maxWidth: maxWidth)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private struct CardRowLabeledContentStyle: LabeledContentStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 0)
                configuration.content
            }
        }
    }

    private struct CardRowToggleStyle: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 0)
                Toggle("", isOn: configuration.$isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }
#endif
