//
//  AppConfiguration.swift
//  ShareCore
//
//  Created by AI Assistant on 2025/12/31.
//

import Foundation

/// Root configuration structure for import/export
/// Now only contains actions - preferences and TTS are managed by UserDefaults
public struct AppConfiguration: Codable, Sendable {
    public var version: String
    public var actions: [ActionEntry]

    /// Single source of truth for the current configuration version.
    public static let currentVersion = "1.6.0"

    public init(
        version: String = AppConfiguration.currentVersion,
        actions: [ActionEntry] = []
    ) {
        self.version = version
        self.actions = actions
    }
}

// MARK: - Action

public extension AppConfiguration {
    struct ActionEntry: Codable, Sendable {
        public var id: String?
        public var name: String
        public var prompt: String
        public var outputType: String?
        public var category: String?

        public init(
            id: String? = nil,
            name: String,
            prompt: String,
            outputType: String? = nil,
            category: String? = nil
        ) {
            self.id = id
            self.name = name
            self.prompt = prompt
            self.outputType = outputType
            self.category = category
        }

        /// Convert to internal ActionConfig
        public func toActionConfig() -> ActionConfig {
            let resolvedOutputType = OutputType(rawValue: outputType ?? "") ?? .markdown
            let resolvedCategory = category.flatMap(ActionConfig.ActionCategory.init(rawValue:))

            return ActionConfig(
                id: id ?? UUID().uuidString,
                name: name,
                prompt: prompt,
                outputType: resolvedOutputType,
                category: resolvedCategory
            )
        }

        /// Create from internal ActionConfig
        public static func from(_ config: ActionConfig) -> ActionEntry {
            ActionEntry(
                id: config.id,
                name: config.name,
                prompt: config.prompt,
                outputType: config.outputType == .markdown ? nil : config.outputType.rawValue,
                category: config.category == .general ? nil : config.category.rawValue
            )
        }
    }
}
