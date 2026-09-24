#if os(macOS)
    import SwiftUI

    public struct RealtimeLaneWorkspace: View {
        @Environment(\.colorScheme) private var colorScheme
        @ObservedObject var store: RealtimeSessionStore

        private let minimumLaneWidth: CGFloat = 320
        private let laneSpacing: CGFloat = 12
        private let workspacePadding: CGFloat = 16
        private let accentTheme: AccentTheme
        private let sourceLanguage: SourceLanguageOption

        public init(
            store: RealtimeSessionStore,
            accentTheme: AccentTheme = .default,
            sourceLanguage: SourceLanguageOption = .auto
        ) {
            self.store = store
            self.accentTheme = accentTheme
            self.sourceLanguage = sourceLanguage
        }

        private var colors: AppColors.Palette {
            AppColors.Palette(colorScheme: colorScheme, accentTheme: accentTheme)
        }

        public var body: some View {
            GeometryReader { geometry in
                let laneCount = max(store.laneConfigurations.count, 1)
                let totalSpacing = laneSpacing * CGFloat(max(laneCount - 1, 0))
                let availableWidth = max(
                    geometry.size.width - workspacePadding * 2 - totalSpacing,
                    minimumLaneWidth
                )
                let laneWidth = max(availableWidth / CGFloat(laneCount), minimumLaneWidth)
                let usesHorizontalScrolling = laneWidth * CGFloat(laneCount) + totalSpacing >
                    geometry.size.width - workspacePadding * 2

                ScrollView(.horizontal) {
                    LazyHStack(spacing: laneSpacing) {
                        ForEach(store.laneConfigurations) { configuration in
                            RealtimeLaneColumn(
                                store: store,
                                configuration: configuration,
                                snapshot: store.laneSnapshots.first(where: { $0.id == configuration.id }),
                                colors: colors,
                                minimumWidth: minimumLaneWidth,
                                sourceLanguage: sourceLanguage
                            )
                            .frame(width: laneWidth)
                        }
                    }
                    .padding(workspacePadding)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .leading)
                }
                .scrollIndicators(usesHorizontalScrolling ? .visible : .hidden)
                .scrollDisabled(!usesHorizontalScrolling)
                .background(colors.background)
            }
        }
    }
#endif
