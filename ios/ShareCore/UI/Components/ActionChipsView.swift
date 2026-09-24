import SwiftUI

public struct ActionChipsView<Background: View>: View {
    let actions: [ActionConfig]
    let selectedActionID: ActionConfig.ID?
    let spacing: CGFloat
    let contentVerticalPadding: CGFloat
    let font: Font
    let textColor: (Bool) -> Color
    let background: (Bool) -> Background
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let onSelect: (ActionConfig) -> Void

    public init(
        actions: [ActionConfig],
        selectedActionID: ActionConfig.ID?,
        spacing: CGFloat = 8,
        contentVerticalPadding: CGFloat = 0,
        font: Font = .system(size: 13, weight: .medium),
        textColor: @escaping (Bool) -> Color,
        background: @escaping (Bool) -> Background,
        horizontalPadding: CGFloat = 14,
        verticalPadding: CGFloat = 8,
        onSelect: @escaping (ActionConfig) -> Void
    ) {
        self.actions = actions
        self.selectedActionID = selectedActionID
        self.spacing = spacing
        self.contentVerticalPadding = contentVerticalPadding
        self.font = font
        self.textColor = textColor
        self.background = background
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                ForEach(actions) { action in
                    let isSelected = action.id == selectedActionID
                    Button {
                        onSelect(action)
                    } label: {
                        Text(action.displayName)
                            .font(font)
                            .foregroundColor(textColor(isSelected))
                            .padding(.horizontal, horizontalPadding)
                            .padding(.vertical, verticalPadding)
                            .background(background(isSelected))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, contentVerticalPadding)
        }
    }
}
