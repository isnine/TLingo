//
//  PromptSubstitution.swift
//  ShareCore
//

import Foundation

public struct PromptLanguageDependencies: Hashable, Sendable {
    public static let none = PromptLanguageDependencies()

    public let usesSourceLanguage: Bool
    public let usesTargetLanguage: Bool
    public let usesAppLanguage: Bool

    public init(
        usesSourceLanguage: Bool = false,
        usesTargetLanguage: Bool = false,
        usesAppLanguage: Bool = false
    ) {
        self.usesSourceLanguage = usesSourceLanguage
        self.usesTargetLanguage = usesTargetLanguage
        self.usesAppLanguage = usesAppLanguage
    }

    public var usesAnyLanguage: Bool {
        usesSourceLanguage || usesTargetLanguage || usesAppLanguage
    }

    var usesDirectionalLanguageControls: Bool {
        usesSourceLanguage || usesTargetLanguage
    }
}

/// Pure-function prompt placeholder substitution.
///
/// Replaces both `{placeholder}` and `{{placeholder}}` variants.
/// Double-brace forms are replaced first so that `{{x}}` is not
/// partially matched by the single-brace pass.
public enum PromptSubstitution {
    private static let placeholders: [(name: String, replacement: (String, String, String) -> String)] = [
        ("targetLanguage", { _, targetLanguage, _ in targetLanguage }),
        ("sourceLanguage", { _, _, sourceLanguage in sourceLanguage }),
        ("appLanguage", { _, _, _ in TargetLanguageOption.appLanguageEnglishName }),
        ("text", { text, _, _ in text }),
    ]

    /// Supported placeholders:
    /// - `{text}` / `{{text}}`                     - user input text
    /// - `{targetLanguage}` / `{{targetLanguage}}` - target language descriptor
    /// - `{sourceLanguage}` / `{{sourceLanguage}}` - source language descriptor (empty when Auto)
    /// - `{appLanguage}` / `{{appLanguage}}`       - current app language descriptor
    public static func substitute(
        prompt: String,
        text: String,
        targetLanguage: String,
        sourceLanguage: String
    ) -> String {
        var result = prompt

        for placeholder in placeholders {
            let value = placeholder.replacement(text, targetLanguage, sourceLanguage)
            result = result.replacingOccurrences(of: "{{\(placeholder.name)}}", with: value)
            result = result.replacingOccurrences(of: "{\(placeholder.name)}", with: value)
        }

        return result
    }

    /// Whether the original prompt template contains a `{text}` or `{{text}}` placeholder.
    public static func containsTextPlaceholder(_ prompt: String) -> Bool {
        containsPlaceholder("text", in: prompt)
    }

    public static func languageDependencies(in prompt: String) -> PromptLanguageDependencies {
        PromptLanguageDependencies(
            usesSourceLanguage: containsSourceLanguagePlaceholder(prompt),
            usesTargetLanguage: containsTargetLanguagePlaceholder(prompt),
            usesAppLanguage: containsAppLanguagePlaceholder(prompt)
        )
    }

    public static func containsSourceLanguagePlaceholder(_ prompt: String) -> Bool {
        containsPlaceholder("sourceLanguage", in: prompt)
    }

    public static func containsTargetLanguagePlaceholder(_ prompt: String) -> Bool {
        containsPlaceholder("targetLanguage", in: prompt)
    }

    public static func containsAppLanguagePlaceholder(_ prompt: String) -> Bool {
        containsPlaceholder("appLanguage", in: prompt)
    }

    private static func containsPlaceholder(_ name: String, in prompt: String) -> Bool {
        prompt.contains("{{\(name)}}") || prompt.contains("{\(name)}")
    }
}
