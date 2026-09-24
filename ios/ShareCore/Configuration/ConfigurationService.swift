//
//  ConfigurationService.swift
//  ShareCore
//
//  Created by AI Assistant on 2025/12/31.
//

import Foundation
import os

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "ConfigService")

/// Service for importing and exporting app configuration as JSON
public final class ConfigurationService: Sendable {
    public static let shared = ConfigurationService()

    private init() {}

    // MARK: - Export

    /// Export current configuration to JSON data
    @MainActor
    public func exportConfiguration(
        from store: AppConfigurationStore,
        preferences: AppPreferences
    ) -> Data? {
        let config = buildAppConfiguration(from: store, preferences: preferences)
        return encodeConfiguration(config)
    }

    /// Export current configuration to a formatted JSON string
    @MainActor
    public func exportConfigurationString(
        from store: AppConfigurationStore,
        preferences: AppPreferences
    ) -> String? {
        guard let data = exportConfiguration(from: store, preferences: preferences) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Import

    /// Import configuration from JSON data
    public func importConfiguration(
        from data: Data
    ) -> Result<AppConfiguration, ConfigurationError> {
        do {
            let decoder = JSONDecoder()
            let decodedConfig = try decoder.decode(AppConfiguration.self, from: data)
            let (migratedConfig, _) = ConfigurationMigrator.migrateIfNeeded(decodedConfig)
            let config = BuiltInActionCatalog.customConfiguration(from: migratedConfig).config

            // Use ConfigurationValidator for comprehensive validation
            let validationResult = ConfigurationValidator.shared.validate(config)

            // Only fail on errors, not warnings
            if validationResult.hasErrors {
                return .failure(.validationFailed(validationResult))
            }

            return .success(config)
        } catch {
            return .failure(.decodingFailed(error))
        }
    }

    /// Import configuration from JSON string
    public func importConfiguration(
        from jsonString: String
    ) -> Result<AppConfiguration, ConfigurationError> {
        guard let data = jsonString.data(using: .utf8) else {
            return .failure(.invalidData)
        }
        return importConfiguration(from: data)
    }

    /// Apply imported configuration to the app
    @MainActor
    public func applyConfiguration(
        _ config: AppConfiguration,
        to store: AppConfigurationStore,
        preferences _: AppPreferences,
        configurationName: String? = nil
    ) {
        logger.debug("Applying configuration: '\(configurationName ?? "unnamed", privacy: .public)'")
        // Build actions (actions is now an array)
        var actions: [ActionConfig] = []
        for entry in config.actions {
            let action = entry.toActionConfig()
            actions.append(action)
        }
        logger.debug("  - Loaded \(actions.count, privacy: .public) actions")

        // IMPORTANT: Set configuration name BEFORE updating actions
        // This ensures the configuration is properly tracked
        if let name = configurationName {
            store.setCurrentConfigurationName(name)
            logger.debug("  - Set configuration name: '\(name, privacy: .public)'")
        } else {
            store.setCurrentConfigurationName(nil)
            logger.debug("  - Set configuration name to nil")
        }

        // Apply actions directly (bypassing the default-mode check)
        store.applyActionsDirectly(actions)

        logger.info("Configuration applied successfully")
    }

    // MARK: - Private Helpers

    @MainActor
    private func buildAppConfiguration(
        from store: AppConfigurationStore,
        preferences _: AppPreferences
    ) -> AppConfiguration {
        // Build action entries (as array to preserve order)
        let actionEntries = store.customActions.map { action in
            AppConfiguration.ActionEntry.from(action)
        }

        return AppConfiguration(
            version: AppConfiguration.currentVersion,
            actions: actionEntries
        )
    }

    private func encodeConfiguration(_ config: AppConfiguration) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(config)
    }

    /// Validate configuration before saving
    /// Returns validation result with all issues found
    @MainActor
    public func validateCurrentConfiguration(
        from store: AppConfigurationStore,
        preferences: AppPreferences
    ) -> ConfigurationValidationResult {
        // First validate in-memory configuration
        let inMemoryResult = ConfigurationValidator.shared.validateInMemory(
            actions: store.customActions
        )

        // Then build and validate the full configuration
        let config = buildAppConfiguration(from: store, preferences: preferences)
        let fullResult = ConfigurationValidator.shared.validate(config)

        // Combine issues (deduplicate if needed)
        let allIssues = inMemoryResult.issues + fullResult.issues.filter { issue in
            !inMemoryResult.issues.contains(issue)
        }

        return ConfigurationValidationResult(issues: allIssues)
    }
}

// MARK: - Errors

public enum ConfigurationError: LocalizedError, Sendable {
    case invalidData
    case decodingFailed(Error)
    case encodingFailed(Error)
    case unsupportedVersion(String)
    case validationFailed(ConfigurationValidationResult)
    case fileNotFound(name: String)
    case fileWriteFailed(Error)
    case fileReadFailed(Error)
    case bundledConfigNotFound
    case noActiveConfiguration
    case saveSuspended

    public var errorDescription: String? {
        switch self {
        case .invalidData:
            return String(localized: "Invalid configuration data")
        case let .decodingFailed(error):
            return String(localized: "Failed to decode configuration: \(error.localizedDescription)")
        case let .encodingFailed(error):
            return String(localized: "Failed to encode configuration: \(error.localizedDescription)")
        case let .unsupportedVersion(version):
            return String(localized: "Unsupported configuration version: \(version)")
        case let .validationFailed(result):
            let errorMessages = result.errors.map(\.message).joined(separator: "; ")
            return String(localized: "Configuration validation failed: \(errorMessages)")
        case let .fileNotFound(name):
            return String(localized: "Configuration file not found: '\(name)'")
        case let .fileWriteFailed(error):
            return String(localized: "Failed to write configuration file: \(error.localizedDescription)")
        case let .fileReadFailed(error):
            return String(localized: "Failed to read configuration file: \(error.localizedDescription)")
        case .bundledConfigNotFound:
            return String(localized: "Bundled default configuration not found in app bundle")
        case .noActiveConfiguration:
            return String(localized: "No active configuration to save")
        case .saveSuspended:
            return String(localized: "Configuration saving is temporarily suspended")
        }
    }
}
