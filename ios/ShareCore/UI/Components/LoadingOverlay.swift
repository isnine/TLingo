import SwiftUI

public struct LoadingOverlay: View {
    let message: String
    let backgroundColor: Color
    let messageFont: Font
    let textColor: Color
    let accentColor: Color
    let ignoresSafeArea: Bool

    public init(
        message: String = "Loading...",
        backgroundColor: Color,
        messageFont: Font = .system(size: 13),
        textColor: Color,
        accentColor: Color,
        ignoresSafeArea: Bool = false
    ) {
        self.message = message
        self.backgroundColor = backgroundColor
        self.messageFont = messageFont
        self.textColor = textColor
        self.accentColor = accentColor
        self.ignoresSafeArea = ignoresSafeArea
    }

    public var body: some View {
        ZStack {
            backgroundColor
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(accentColor)
                    .controlSize(.regular)
                Text(message)
                    .font(messageFont)
                    .foregroundColor(textColor)
            }
        }
        .modifier(IgnoresSafeAreaModifier(enabled: ignoresSafeArea))
    }
}

private struct IgnoresSafeAreaModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.ignoresSafeArea()
        } else {
            content
        }
    }
}
