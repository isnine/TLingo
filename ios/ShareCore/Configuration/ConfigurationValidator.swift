//
//  ConfigurationValidator.swift
//  ShareCore
//
//  Created by AI Assistant on 2026/01/01.
//

import Foundation

/// Validates configuration integrity and compatibility
public struct ConfigurationValidator: Sendable {
    public static let shared = ConfigurationValidator()

    /// Current supported major version
    public static let currentMajorVersion = 1

    /// Supported major version range (inclusive)
    public static let supportedVersionRange = 1 ... 1

    private init() {}

    // MARK: - Full Configuration Validation

    /// Validate an AppConfiguration and return all issues found
    public func validate(_ config: AppConfiguration) -> ConfigurationValidationResult {
        var issues: [ConfigurationValidationIssue] = []

        // 1. Version validation
        issues.append(contentsOf: validateVersion(config.version))

        // 2. Action validation
        issues.append(contentsOf: validateActions(config.actions))

        return ConfigurationValidationResult(issues: issues)
    }

    /// Validate in-memory configuration (actions only)
    @MainActor
    public func validateInMemory(
        actions: [ActionConfig]
    ) -> ConfigurationValidationResult {
        var issues: [ConfigurationValidationIssue] = []

        // Validate each action
        for action in actions {
            // Validate action has a name
            if action.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.emptyActionName)
            }

            // Validate action has a prompt
            if action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.emptyActionPrompt(actionName: action.name))
            }
        }

        // Check for duplicate action names
        var seenNames: Set<String> = []
        for action in actions {
            if seenNames.contains(action.name) {
                issues.append(.duplicateActionName(actionName: action.name))
            }
            seenNames.insert(action.name)
        }

        return ConfigurationValidationResult(issues: issues)
    }

    // MARK: - Version Validation

    private func validateVersion(_ version: String) -> [ConfigurationValidationIssue] {
        var issues: [ConfigurationValidationIssue] = []

        let components = version.split(separator: ".").compactMap { Int($0) }

        guard components.count >= 2 else {
            issues.append(.invalidVersionFormat(version: version))
            return issues
        }

        let major = components[0]

        if !Self.supportedVersionRange.contains(major) {
            issues.append(
                .unsupportedVersion(
                    version: version,
                    supportedRange: "\(Self.supportedVersionRange.lowerBound).x.x - \(Self.supportedVersionRange.upperBound).x.x"
                )
            )
        }

        return issues
    }

    // MARK: - Action Validation

    private func validateActions(
        _ actions: [AppConfiguration.ActionEntry]
    ) -> [ConfigurationValidationIssue] {
        var issues: [ConfigurationValidationIssue] = []

        for action in actions {
            // Validate action has a name
            if action.name.isEmpty {
                issues.append(.emptyActionName)
            }

            // Validate action has a prompt
            if action.prompt.isEmpty {
                issues.append(.emptyActionPrompt(actionName: action.name))
            }

            // Validate output type
            if let outputType = action.outputType,
               OutputType(rawValue: outputType) == nil
            {
                issues.append(.invalidOutputType(actionName: action.name, outputType: outputType))
            }
        }

        // Check for duplicate action names
        var seenNames: Set<String> = []
        for action in actions {
            if seenNames.contains(action.name) {
                issues.append(.duplicateActionName(actionName: action.name))
            }
            seenNames.insert(action.name)
        }

        return issues
    }
}

// MARK: - Validation Result

public struct ConfigurationValidationResult: Sendable {
    public let issues: [ConfigurationValidationIssue]

    public var isValid: Bool {
        !hasErrors
    }

    public var hasErrors: Bool {
        issues.contains { $0.severity == .error }
    }

    public var hasWarnings: Bool {
        issues.contains { $0.severity == .warning }
    }

    public var errors: [ConfigurationValidationIssue] {
        issues.filter { $0.severity == .error }
    }

    public var warnings: [ConfigurationValidationIssue] {
        issues.filter { $0.severity == .warning }
    }

    public init(issues: [ConfigurationValidationIssue]) {
        self.issues = issues
    }

    /// Empty result with no issues
    public static let valid = ConfigurationValidationResult(issues: [])
}

// MARK: - Validation Issue

public enum ConfigurationValidationIssue: Sendable, Equatable {
    // Version issues
    case invalidVersionFormat(version: String)
    case unsupportedVersion(version: String, supportedRange: String)

    // Action issues
    case emptyActionName
    case emptyActionPrompt(actionName: String)
    case invalidOutputType(actionName: String, outputType: String)
    case duplicateActionName(actionName: String)

    /// Severity level of the issue
    public var severity: ValidationSeverity {
        switch self {
        // Errors - prevent saving or loading
        case .invalidVersionFormat,
             .unsupportedVersion,
             .invalidOutputType:
            return .error

        // Warnings - allow saving but notify user
        case .emptyActionName,
             .emptyActionPrompt,
             .duplicateActionName:
            return .warning
        }
    }

    /// Human-readable description
    public var message: String {
        switch self {
        case let .invalidVersionFormat(version):
            return String(localized: "Invalid version format: '\(version)'. Expected format: X.Y.Z")
        case let .unsupportedVersion(version, supportedRange):
            return String(localized: "Version '\(version)' is not supported. Supported range: \(supportedRange)")
        case .emptyActionName:
            return String(localized: "Action has empty name")
        case let .emptyActionPrompt(actionName):
            return String(localized: "Action '\(actionName)' has empty prompt")
        case let .invalidOutputType(actionName, outputType):
            return String(localized: "Action '\(actionName)' has invalid output type: '\(outputType)'")
        case let .duplicateActionName(actionName):
            return String(localized: "Duplicate action name: '\(actionName)'")
        }
    }
}

// MARK: - Severity

public enum ValidationSeverity: String, Sendable {
    case error
    case warning
}
