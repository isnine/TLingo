import SwiftUI

struct ResultReadingStyle: Codable, Equatable, Hashable, Sendable {
    var fontName: String?
    var textSize: Double = 15

    var scale: CGFloat {
        CGFloat(textSize / 15)
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let fontName {
            return .custom(fontName, size: size * scale, relativeTo: .body).weight(weight)
        }
        return .system(size: size * scale, weight: weight)
    }
}
