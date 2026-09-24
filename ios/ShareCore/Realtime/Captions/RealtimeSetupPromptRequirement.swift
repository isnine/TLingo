//
//  RealtimeSetupPromptRequirement.swift
//  ShareCore
//

public enum RealtimeSetupPromptRequirement: Equatable {
    case none
    case languageSelection

    public static func evaluate(
        hasMissingPermission: Bool,
        sourceLanguage: SourceLanguageOption,
        targetLanguage: TargetLanguageOption,
        requiresTargetLanguage: Bool = true
    ) -> RealtimeSetupPromptRequirement {
        guard !hasMissingPermission else { return .none }

        return hasRequiredLanguageSelection(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            requiresTargetLanguage: requiresTargetLanguage
        ) ? .none : .languageSelection
    }

    public static func hasRequiredLanguageSelection(
        sourceLanguage: SourceLanguageOption,
        targetLanguage: TargetLanguageOption,
        requiresTargetLanguage: Bool = true
    ) -> Bool {
        sourceLanguage != .auto &&
            (!requiresTargetLanguage || targetLanguage != .appLanguage)
    }
}
