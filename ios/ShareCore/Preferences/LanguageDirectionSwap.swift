//
//  LanguageDirectionSwap.swift
//  ShareCore
//

public enum LanguageDirectionSwap {
    public struct Result: Equatable {
        public let source: SourceLanguageOption
        public let target: TargetLanguageOption
    }

    public static func swapped(
        source: SourceLanguageOption,
        target: TargetLanguageOption,
        resolvedSource: SourceLanguageOption? = nil,
        resolvedTarget: TargetLanguageOption? = nil
    ) -> Result {
        let effectiveSource = source == .auto ? resolvedSource ?? source : source
        let effectiveTarget = target == .appLanguage ? resolvedTarget ?? target : target
        return Result(
            source: sourceOption(from: effectiveTarget),
            target: targetOption(from: effectiveSource)
        )
    }

    /// True when translating would be a no-op, e.g. "en" → "en-US". Two regional variants
    /// ("en-GB" → "en-US", "zh-Hans" → "zh-Hant") remain a valid direction.
    public static func isSameLanguage(source: SourceLanguageOption, target: TargetLanguageOption) -> Bool {
        guard source != .auto, target != .appLanguage else { return false }
        if source.rawValue == target.rawValue {
            return true
        }
        let sourceParts = source.rawValue.split(separator: "-")
        let targetParts = target.rawValue.split(separator: "-")
        return sourceParts.first == targetParts.first && (sourceParts.count == 1 || targetParts.count == 1)
    }

    private static func sourceOption(from target: TargetLanguageOption) -> SourceLanguageOption {
        if target == .appLanguage {
            return .auto
        }
        guard let source = SourceLanguageOption(rawValue: target.rawValue) else {
            preconditionFailure("Target language has no source-language equivalent: \(target.rawValue)")
        }
        return source
    }

    private static func targetOption(from source: SourceLanguageOption) -> TargetLanguageOption {
        if source == .auto {
            return .appLanguage
        }
        guard let target = TargetLanguageOption(rawValue: source.rawValue) else {
            preconditionFailure("Source language has no target-language equivalent: \(source.rawValue)")
        }
        return target
    }
}
