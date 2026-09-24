//
//  ActionConfig.swift
//  ShareCore
//
//  Created by Codex on 2025/10/19.
//

import Foundation

/// Represents a single sentence pair with original and translated text.
public struct SentencePair: Codable, Hashable, Identifiable, Sendable {
    public var id: String { original + translation }
    public let original: String
    public let translation: String

    public init(original: String, translation: String) {
        self.original = original
        self.translation = translation
    }

    enum CodingKeys: String, CodingKey {
        case original, translation
    }
}

public struct ActionConfig: Identifiable, Hashable, Codable, Sendable {
    /// Categorizes whether an action is a translation task or a general text-processing task.
    /// Only `.translation` actions are eligible for on-device Apple Translate.
    public enum ActionCategory: String, Codable, Hashable, Sendable {
        case translation
        case general
    }

    /// Controls how the result is displayed in the UI.
    public enum DisplayMode: String, Codable, Hashable, Sendable {
        /// Default text display with copy/speak buttons.
        case standard
        /// Sentence-by-sentence alternating rows (original + translation).
        case sentencePairs
    }

    public struct StructuredOutputConfig: Codable, Hashable, Sendable {
        public let primaryField: String
        public let additionalFields: [String]
        public let jsonSchema: String

        public init(primaryField: String, additionalFields: [String], jsonSchema: String) {
            self.primaryField = primaryField
            self.additionalFields = additionalFields
            self.jsonSchema = jsonSchema
        }

        public func responseFormatPayload() -> [String: Any]? {
            guard let schemaObject = jsonSchemaObject() else {
                return nil
            }

            return [
                "type": "json_schema",
                "json_schema": schemaObject,
            ]
        }

        private func jsonSchemaObject() -> [String: Any]? {
            guard let data = jsonSchema.data(using: .utf8) else {
                return nil
            }
            let object = try? JSONSerialization.jsonObject(with: data, options: [])
            return object as? [String: Any]
        }
    }

    public let id: UUID
    public var name: String
    public var prompt: String
    public var outputType: OutputType
    public var category: ActionCategory

    /// Computed property for backward compatibility
    public var showsDiff: Bool {
        outputType.showsDiff
    }

    /// Computed property for backward compatibility
    public var structuredOutput: StructuredOutputConfig? {
        if outputType == .diff || outputType == .translate {
            guard BuiltInActionCatalog.isBuiltInAction(self) else { return nil }
        }
        return outputType.structuredOutput
    }

    /// Computed property for backward compatibility
    public var displayMode: DisplayMode {
        outputType.displayMode
    }

    /// Whether Apple Translate can handle this action.
    public var supportsAppleTranslate: Bool {
        outputType == .translate || outputType == .sentencePairs
    }

    public var languageDependencies: PromptLanguageDependencies {
        PromptSubstitution.languageDependencies(in: prompt)
    }

    public var displayName: String {
        BuiltInActionCatalog.displayName(for: self)
    }

    /// Primary initializer
    public init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        outputType: OutputType = .plain,
        category: ActionCategory = .general
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.outputType = outputType
        self.category = category
    }
}
