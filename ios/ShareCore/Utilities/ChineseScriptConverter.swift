import Foundation

struct ChineseScriptConverter {
    static let simplifiedTransform = StringTransform("Traditional-Simplified")
    static let traditionalTransform = StringTransform("Simplified-Traditional")

    private let transform: StringTransform

    init?(source: Locale.Language?, target: Locale.Language) {
        guard let source,
              source.languageCode?.identifier == "zh",
              target.languageCode?.identifier == "zh",
              let sourceScript = source.script?.identifier,
              let targetScript = target.script?.identifier,
              sourceScript != targetScript
        else {
            return nil
        }
        switch (sourceScript, targetScript) {
        case ("Hant", "Hans"):
            transform = Self.simplifiedTransform
        case ("Hans", "Hant"):
            transform = Self.traditionalTransform
        default:
            return nil
        }
    }

    func convert(_ text: String) throws -> String {
        guard let converted = text.applyingTransform(transform, reverse: false) else {
            throw CocoaError(.formatting)
        }
        return converted
    }
}
