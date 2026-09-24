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
