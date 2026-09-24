#if os(iOS) && !targetEnvironment(macCatalyst)
    import ShareCore
    import SwiftUI

    struct DefaultTranslationSnapshotView: View {
        @Environment(\.colorScheme) private var colorScheme
        @StateObject private var viewModel = HomeViewModel()

        private var snapshotLocale: SnapshotLocaleConfiguration {
            SnapshotLocaleCatalog.current()
        }

        private var colors: AppColorPalette {
            AppColors.palette(for: colorScheme)
        }

        var body: some View {
            ZStack(alignment: .bottom) {
                selectedTextSurface
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12))

                extensionPanel
            }
            .background(colors.background.ignoresSafeArea())
        }

        private var selectedTextSurface: some View {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(systemName: "doc.text")
                        .font(.system(size: 18, weight: .semibold))
                    Text(snapshotLocale.documentTitle)
                        .font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                }
                .foregroundStyle(colors.textPrimary)

                Text(snapshotLocale.extensionSourceText)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(colors.textPrimary)
                    .lineSpacing(5)
                    .padding(10)
                    .background(colors.accent.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colors.background)
        }

        private var extensionPanel: some View {
            VStack(spacing: 0) {
                Capsule()
                    .fill(colors.textSecondary.opacity(0.35))
                    .frame(width: 38, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                HStack {
                    Text(snapshotLocale.extensionTitle)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                    Spacer()
                    Button {} label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(colors.textSecondary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 20)

                CompactTranslationView(
                    viewModel: viewModel,
                    onReplace: nil,
                    onConversation: nil,
                    usesCompactSnapshotMetrics: true
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: 570)
            .background(colors.background)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 28,
                    topTrailingRadius: 28
                )
            )
            .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: -6)
        }
    }
#endif
