//
//  AppConfigurationStore.swift
//  ShareCore
//
//  Created by Codex on 2025/10/19.
//

import Combine
import Foundation
import os

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "ConfigStore")

@MainActor
public final class AppConfigurationStore: ObservableObject {
    public static let shared = AppConfigurationStore()

    /// Snapshot-only store: avoids file IO / observers so it can be rendered offscreen reliably.
    public static func makeSnapshotStore() -> AppConfigurationStore {
        AppConfigurationStore(snapshot: true)
    }

    public nonisolated static var builtInActions: [ActionConfig] {
        BuiltInActionCatalog.actions
    }

    public nonisolated static func customActions(from actions: [ActionConfig]) -> [ActionConfig] {
        BuiltInActionCatalog.customActions(from: actions)
    }

    public nonisolated static func displayName(forActionName name: String) -> String {
        BuiltInActionCatalog.displayName(forActionName: name)
    }

    @Published public private(set) var actions: [ActionConfig]
    @Published public private(set) var customActions: [ActionConfig]
    @Published public private(set) var currentConfigurationName: String?

    /// Publisher to notify UI that configuration was switched and UI should sync from preferences
    public let configurationSwitchedPublisher = PassthroughSubject<Void, Never>()

    /// Last validation result from loading or saving
    @Published public private(set) var lastValidationResult: ConfigurationValidationResult?

    /// Whether auto-save is currently suspended (to prevent save loops during file reload)
    private var isSaveSuspended = false

    /// Timestamp of last file modification we initiated
    private var lastSaveTimestamp: Date?

    /// Debounce interval for file change events (to avoid duplicate reloads)
    private static let fileChangeDebounceInterval: TimeInterval = 0.5

    private let preferences: AppPreferences
    private let configFileManager: ConfigurationFileManager
    private var cancellables: Set<AnyCancellable> = []

    public var defaultAction: ActionConfig? {
        actions.first
    }

    init(
        snapshot: Bool = false,
        preferences: AppPreferences = .shared,
        configFileManager: ConfigurationFileManager = .shared
    ) {
        self.preferences = preferences
        self.configFileManager = configFileManager

        // Initialize with empty arrays first
        actions = []
        customActions = []
        currentConfigurationName = nil
        lastValidationResult = nil

        if snapshot {
            // Minimal, deterministic data for screenshots. No file IO, no observers, no autosave.
            preferences.refreshFromDefaults()
            rebuildActions()
            currentConfigurationName = "Snapshot"
            return
        }

        preferences.refreshFromDefaults()

        // Load from persistence or defaults
        loadConfiguration()

        // Subscribe to file change events
        setupFileChangeObserver()
    }

    // MARK: - File Change Observer

    private func setupFileChangeObserver() {
        configFileManager.fileChangePublisher
            .debounce(for: .seconds(Self.fileChangeDebounceInterval), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleFileChange(event)
                }
            }
            .store(in: &cancellables)
    }

    private func handleFileChange(_ event: ConfigurationFileChangeEvent) async {
        // Only process changes to the current configuration
        guard event.name == currentConfigurationName else { return }

        // Ignore changes we initiated ourselves (within debounce window)
        if let lastSave = lastSaveTimestamp,
           event.timestamp.timeIntervalSince(lastSave) < Self.fileChangeDebounceInterval
        {
            logger.debug("Ignoring file change - self-initiated save")
            return
        }

        switch event.changeType {
        case .modified:
            logger.debug("External file modification detected, reloading...")
            reloadCurrentConfiguration()

        case .deleted:
            logger.warning("Configuration file deleted externally")
            // Try to reload from bundled default
            _ = tryLoadConfiguration(named: "Configuration")

        case .renamed:
            logger.warning("Configuration file renamed externally")
            // Try to find the file under a new name or reload
            reloadCurrentConfiguration()
        }
    }

    // MARK: - Public Methods

    /// Update actions with validation
    @discardableResult
    public func updateActions(
        _ actions: [ActionConfig]
    ) -> Result<ConfigurationValidationResult?, ConfigurationError> {
        updateCustomActions(Self.customActions(from: actions))
    }

    @discardableResult
    public func updateCustomActions(
        _ actions: [ActionConfig]
    ) -> Result<ConfigurationValidationResult?, ConfigurationError> {
        applyActionsUpdate(actions)
    }

    public func isBuiltInAction(_ action: ActionConfig) -> Bool {
        BuiltInActionCatalog.isBuiltInAction(action)
    }

    /// Internal method to actually apply actions update
    private func applyActionsUpdate(
        _ actions: [ActionConfig]
    ) -> Result<ConfigurationValidationResult?, ConfigurationError> {
        let adjusted = Self.customActions(from: actions)

        // Validate before applying
        let validationResult = ConfigurationValidator.shared.validateInMemory(
            actions: adjusted
        )

        lastValidationResult = validationResult

        // Apply changes even with warnings, but log them
        if validationResult.hasWarnings {
            for warning in validationResult.warnings {
                logger.warning("Validation warning: \(warning.message, privacy: .public)")
            }
        }

        guard !validationResult.hasErrors else {
            return .success(validationResult)
        }

        let previousCustomActions = customActions
        customActions = adjusted
        rebuildActions()
        if case let .failure(error) = saveConfiguration() {
            customActions = previousCustomActions
            rebuildActions()
            return .failure(error)
        }

        return .success(validationResult.issues.isEmpty ? nil : validationResult)
    }

    public func setCurrentConfigurationName(_ name: String?) {
        let previousName = currentConfigurationName
        guard previousName != name else { return }

        // Update file monitoring for the old config
        if let previousName {
            configFileManager.stopMonitoring(configurationNamed: previousName)
        }

        currentConfigurationName = name
        preferences.setCurrentConfigName(name)

        // Start monitoring the new config
        if let newName = name {
            configFileManager.startMonitoring(configurationNamed: newName)
        }
    }

    /// Apply actions directly without triggering the default-mode check
    /// Used by ConfigurationService when loading a configuration
    public func applyActionsDirectly(_ actions: [ActionConfig]) {
        customActions = Self.customActions(from: actions)
        rebuildActions()
        // Don't save - this is part of a load operation
    }

    /// Reload the current configuration from disk
    public func reloadCurrentConfiguration() {
        guard let name = currentConfigurationName else { return }

        // Suspend auto-save during reload to prevent loops
        isSaveSuspended = true
        defer { isSaveSuspended = false }

        if tryLoadConfiguration(named: name) {
            let actionCount = actions.count
            logger.info("Reloaded '\(name, privacy: .public)' — \(actionCount, privacy: .public) actions")
        } else {
            logger.error("Failed to reload '\(name, privacy: .public)'")
        }
    }

    /// Validate current in-memory configuration
    public func validateCurrentConfiguration() -> ConfigurationValidationResult {
        let result = ConfigurationValidator.shared.validateInMemory(
            actions: customActions
        )
        lastValidationResult = result
        return result
    }

    /// Force save current configuration (bypassing validation errors)
    public func forceSaveConfiguration() -> Result<Void, ConfigurationError> {
        saveConfiguration(force: true)
    }

    // MARK: - Persistence using ConfigurationFileManager

    private func loadConfiguration() {
        // Copy bundled default to App Group if needed
        configFileManager.copyBundledDefaultIfNeeded(to: "Configuration")

        if let savedName = preferences.currentConfigName,
           savedName != "Configuration",
           configFileManager.configurationExists(named: savedName),
           tryLoadConfiguration(named: savedName)
        {
            logger.info("Restored active configuration '\(savedName, privacy: .public)'")
            return
        }

        if tryLoadConfiguration(named: "Configuration") {
            let actionCount = actions.count
            let actionNames = actions.map(\.name)
            logger
                .info(
                    "Loaded configuration — \(actionCount, privacy: .public) actions: \(actionNames, privacy: .public)"
                )
        } else {
            logger.error("Failed to load configuration, creating empty")
            createEmptyConfiguration()
        }
    }

    private func tryLoadConfiguration(named name: String) -> Bool {
        do {
            let config = try configFileManager.loadConfiguration(named: name)

            // Validate the loaded configuration
            let validationResult = ConfigurationValidator.shared.validate(config)
            lastValidationResult = validationResult

            if validationResult.hasErrors {
                logger.error("Configuration '\(name, privacy: .public)' has validation errors:")
                for error in validationResult.errors {
                    logger.error("  - \(error.message, privacy: .public)")
                }
                // Still load with warnings, but fail on errors
                return false
            }

            if validationResult.hasWarnings {
                logger.warning("Configuration '\(name, privacy: .public)' has validation warnings:")
                for warning in validationResult.warnings {
                    logger.warning("  - \(warning.message, privacy: .public)")
                }
            }

            applyLoadedConfiguration(config)
            currentConfigurationName = name
            preferences.setCurrentConfigName(name)

            // Start monitoring the configuration
            configFileManager.startMonitoring(configurationNamed: name)

            return true
        } catch {
            logger.error("Failed to load config '\(name, privacy: .public)': \(error, privacy: .public)")
            return false
        }
    }

    private func createEmptyConfiguration() {
        customActions = []
        rebuildActions()
        currentConfigurationName = "New Configuration"
        preferences.setCurrentConfigName("New Configuration")

        // Save the empty configuration
        _ = saveConfiguration()
    }

    private func applyLoadedConfiguration(_ config: AppConfiguration) {
        // Build actions (actions is now an array, order is preserved)
        var loadedActions: [ActionConfig] = []
        for entry in config.actions {
            let action = entry.toActionConfig()
            loadedActions.append(action)
        }

        logger.debug("Total loaded actions: \(loadedActions.count, privacy: .public)")

        customActions = Self.customActions(from: loadedActions)
        rebuildActions()
    }

    private func saveConfiguration(force: Bool = false) -> Result<Void, ConfigurationError> {
        // Skip if save is suspended (during reload)
        guard !isSaveSuspended else {
            logger.debug("Save suspended, skipping")
            return .failure(.saveSuspended)
        }

        guard let configName = currentConfigurationName else {
            logger.debug("No current configuration name set, skipping save")
            return .failure(.noActiveConfiguration)
        }

        // Validate before saving (unless forcing)
        if !force {
            let validationResult = validateCurrentConfiguration()
            if validationResult.hasErrors {
                logger.error("Cannot save - validation errors:")
                for error in validationResult.errors {
                    logger.error("  - \(error.message, privacy: .public)")
                }
                return .failure(.validationFailed(validationResult))
            }
        }

        let config = buildCurrentConfiguration()

        do {
            try configFileManager.saveConfiguration(config, name: configName)
            lastSaveTimestamp = Date()
            logger.info("Saved configuration to '\(configName, privacy: .public).json'")
            return .success(())
        } catch {
            logger.error("Failed to save configuration: \(error, privacy: .public)")
            return .failure(.fileWriteFailed(error))
        }
    }

    private func buildCurrentConfiguration() -> AppConfiguration {
        // Build action entries (as array to preserve order)
        let actionEntries = customActions.map { action in
            AppConfiguration.ActionEntry.from(action)
        }

        return AppConfiguration(
            version: AppConfiguration.currentVersion,
            actions: actionEntries
        )
    }

    /// Reset to bundled default configuration (read-only mode)
    public func resetToDefault() {
        // Stop monitoring current config
        if let name = currentConfigurationName {
            configFileManager.stopMonitoring(configurationNamed: name)
        }

        if let name = currentConfigurationName {
            do {
                try configFileManager.deleteConfiguration(named: name)
            } catch {
                logger.error("Failed to delete configuration: \(error, privacy: .public)")
            }
        }

        loadConfiguration()
    }

    private func rebuildActions() {
        actions = Self.builtInActions + customActions
    }
}
