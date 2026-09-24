import SwiftUI

public struct HistoryMarkdownText: View {
    private let text: String
    private let font: Font
    private let foregroundColor: Color
    private let lineLimit: Int?
    private let emphasizesStructure: Bool

    public init(
        text: String,
        font: Font,
        foregroundColor: Color,
        lineLimit: Int? = nil,
        emphasizesStructure: Bool = false
    ) {
        self.text = text
        self.font = font
        self.foregroundColor = foregroundColor
        self.lineLimit = lineLimit
        self.emphasizesStructure = emphasizesStructure
    }

    @ViewBuilder
    public var body: some View {
        MarkdownContentView(
            text: text,
            preset: emphasizesStructure ? .detail : .fixed(font),
            textColor: foregroundColor,
            lineLimit: lineLimit
        )
    }
}
