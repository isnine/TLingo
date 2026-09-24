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

    public nonisolated static func isBuiltInActionName(_ name: String) -> Bool {
        BuiltInActionCatalog.isBuiltInActionName(name)
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

        // Use dropFirst() to skip the initial value emission,
        // so we only save on actual user-initiated changes
        preferences.$targetLanguage
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let updated = AppConfigurationStore.applyManagedTemplates(self.customActions)
                self.customActions = updated
                self.rebuildActions()
                _ = self.saveConfiguration()
            }
            .store(in: &cancellables)
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
        let adjusted = AppConfigurationStore.applyManagedTemplates(Self.customActions(from: actions))

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
        let adjusted = AppConfigurationStore.applyManagedTemplates(Self.customActions(from: actions))
        customActions = adjusted
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

    /// Minimum supported configuration version
    private static let minimumVersion = "1.1.0"

    /// Check if a configuration version is compatible (>= 1.1.0)
    private func isVersionCompatible(_ version: String) -> Bool {
        // version >= minimumVersion  ⟺  !(version < minimumVersion)
        !ConfigurationMigrator.versionCompare(version, isLessThan: Self.minimumVersion)
    }

    private func tryLoadConfiguration(named name: String) -> Bool {
        do {
            var config = try configFileManager.loadConfiguration(named: name)

            // Check version compatibility - require 1.1.0 or higher
            if !isVersionCompatible(config.version) {
                logger
                    .warning(
                        "Configuration '\(name, privacy: .public)' has incompatible version: \(config.version, privacy: .public)"
                    )
                return false
            }

            // Migrate to current version if needed
            let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)
            config = migrated
            let filtered = BuiltInActionCatalog.customConfiguration(from: config)
            config = filtered.config

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

            // Persist the migrated configuration so the migration is not repeated
            if didMigrate || filtered.removedBuiltInActions {
                logger.debug("Persisting migrated configuration '\(name, privacy: .public)'")
                _ = saveConfiguration(force: true)
            }

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

        customActions = AppConfigurationStore.applyManagedTemplates(Self.customActions(from: loadedActions))
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

    private static func applyManagedTemplates(_ actions: [ActionConfig]) -> [ActionConfig] {
        actions.map { action in
            guard let template = ManagedActionTemplate(action: action) else {
                return action
            }

            var updated = action

            if template.shouldUpdatePrompt(currentPrompt: action.prompt) {
                updated.prompt = template.prompt()
            }

            return updated
        }
    }

    private func rebuildActions() {
        let builtIn = AppConfigurationStore.applyManagedTemplates(Self.builtInActions)
        actions = builtIn + customActions
    }
}

// MARK: - Managed Action Templates (for language updates)

private extension AppConfigurationStore {
    enum ManagedActionTemplate {
        case translate
        case summarize
        case sentenceAnalysis
        case sentenceBySentenceTranslate

        private static let translateName = NSLocalizedString(
            "Translate",
            comment: "Name of the translate action"
        )
        private static let summarizeName = NSLocalizedString(
            "Summarize",
            comment: "Name of the summarize action"
        )
        private static let sentenceAnalysisName = NSLocalizedString(
            "Sentence Analysis",
            comment: "Name of the sentence analysis action"
        )
        private static let sentenceBySentenceTranslateName = NSLocalizedString(
            "Sentence Translate",
            comment: "Name of the sentence-by-sentence translation action"
        )

        private static let translatePromptTemplate =
            BuiltInActionCatalog.prompt(named: "Translate") ?? ""
        private static let previousTranslatePromptTemplate =
            #"Translate: "{text}" from {sourceLanguage} to {targetLanguage} with tone: fluent"#
        private static let translatePromptWithoutSourceTemplate =
            #"Translate: "{text}" to {targetLanguage} with tone: fluent"#
        private static let previousSummarizePromptTemplate = [
            "Summarize the text below in {{targetLanguage}}.",
            "",
            "Text:",
            "{{text}}",
            "",
            "Rules:",
            "- Preserve the essential meaning.",
            "- Do NOT add new information.",
            "- Return only the summary.",
        ].joined(separator: "\n")
        private static let summarizePromptTemplate = [
            "Summarize the text below in {{targetLanguage}}.",
            "",
            "Text:",
            "{{text}}",
            "",
            "Rules:",
            "- Preserve the essential meaning.",
            "- Do NOT add new information.",
            "- Format the result as compact Markdown that renders well in a chat/result cell.",
            "- Use '## Summary' and '## Key Points' headings translated into {{targetLanguage}}.",
            "- Put the short summary under Summary and 2–5 bullets under Key Points.",
            "- Do NOT use code fences, HTML, tables, images, or remote media.",
        ].joined(separator: "\n")
        private static let summarizeLegacyPrompt = "Provide a concise summary of the selected text, preserving the key meaning."

        private static let sentenceAnalysisPromptTemplate =
            BuiltInActionCatalog.prompt(named: "Sentence Analysis") ?? ""
        private static let previousSentenceAnalysisPromptTemplate =
            "Analyze in {{targetLanguage}} using exactly these sections:\n\n" +
            "## 📚语法分析\n" +
            "- Sentence structure (clauses, parts of speech, tense/voice)\n" +
            "- Key grammar patterns\n\n" +
            "## ✍️ 搭配积累\n" +
            "- Useful phrases/collocations with brief meanings and examples\n\n" +
            "Be concise. No extra sections."

        private static let sentenceBySentenceTranslatePromptTemplate =
            BuiltInActionCatalog.prompt(named: "Sentence Translate") ?? ""
        private static let previousSentenceBySentenceTranslatePromptCurrentTemplate =
            "Translate the input sentence by sentence from {{sourceLanguage}} to {{targetLanguage}}. " +
            "Return original-translation pairs. Keep meaning and style."

        private static let sentenceBySentenceTranslatePromptWithoutSourceTemplate =
            "Translate the input sentence by sentence to {{targetLanguage}}. " +
            "Return original-translation pairs. Keep meaning and style."

        private static let previousSentenceBySentenceTranslatePromptTemplate =
            "If input is in {{targetLanguage}}, translate sentence by sentence to English; " +
            "otherwise translate to {{targetLanguage}}. Return original-translation pairs. Keep meaning and style."

        init?(action: ActionConfig) {
            switch action.name {
            case Self.translateName:
                self = .translate
            case Self.summarizeName:
                self = .summarize
            case Self.sentenceAnalysisName:
                self = .sentenceAnalysis
            case Self.sentenceBySentenceTranslateName:
                self = .sentenceBySentenceTranslate
            default:
                return nil
            }
        }

        func prompt() -> String {
            switch self {
            case .translate:
                return Self.translatePromptTemplate
            case .summarize:
                return Self.summarizePromptTemplate
            case .sentenceAnalysis:
                return Self.sentenceAnalysisPromptTemplate
            case .sentenceBySentenceTranslate:
                return Self.sentenceBySentenceTranslatePromptTemplate
            }
        }

        func shouldUpdatePrompt(currentPrompt: String) -> Bool {
            // Also recognize old baked-in-language prompts from pre-1.3 code
            // so they get replaced with template versions
            let legacyGenerated = Set(
                TargetLanguageOption.selectionOptions.map { legacyPrompt(for: $0) }
            )

            switch self {
            case .translate, .summarize, .sentenceAnalysis, .sentenceBySentenceTranslate:
                return currentPrompt == Self.summarizeLegacyPrompt
                    || currentPrompt == Self.previousSummarizePromptTemplate
                    || currentPrompt == Self.previousTranslatePromptTemplate
                    || currentPrompt == Self.translatePromptWithoutSourceTemplate
                    || currentPrompt == Self.previousSentenceAnalysisPromptTemplate
                    || currentPrompt == Self.previousSentenceBySentenceTranslatePromptCurrentTemplate
                    || currentPrompt == Self.sentenceBySentenceTranslatePromptWithoutSourceTemplate
                    || currentPrompt == Self.previousSentenceBySentenceTranslatePromptTemplate
                    || currentPrompt == prompt()
                    || legacyGenerated.contains(currentPrompt)
            }
        }

        /// Returns the old baked-in-language prompt that was generated by pre-1.3 code.
        /// Used by `shouldUpdatePrompt` to recognize prompts that need updating.
        private func legacyPrompt(for language: TargetLanguageOption) -> String {
            switch self {
            case .translate:
                return Self.translatePromptTemplate
            case .summarize:
                return "Provide a concise summary of the selected text in \(language.promptDescriptor). " +
                    "Preserve the essential meaning without adding new information."
            case .sentenceAnalysis:
                return Self.legacySentenceAnalysisPrompt(for: language)
            case .sentenceBySentenceTranslate:
                return Self.legacySentenceBySentenceTranslatePrompt(for: language)
            }
        }

        private static func legacySentenceAnalysisPrompt(for language: TargetLanguageOption) -> String {
            let descriptor = language.promptDescriptor
            return """
            Analyze the provided sentence or short paragraph and respond entirely in \(
                descriptor
            ). Follow exactly two Markdown sections:

            ## 📚语法分析
            - Explain the sentence structure (clauses, parts of speech, tense/voice) and how key components relate.
            - Highlight noteworthy grammar patterns or difficult constructions.

            ## ✍️ 搭配积累
            - List useful short phrases, collocations, or idiomatic chunks from the input.
            - Give each item a brief meaning plus usage tips or a short example.

            Keep explanations concise yet insightful and do not add extra sections.
            """
        }

        private static func legacySentenceBySentenceTranslatePrompt(for language: TargetLanguageOption) -> String {
            let descriptor = language.promptDescriptor
            return """
            Translate the following text sentence by sentence into \(
                descriptor
            ). If the input language already matches the target language, translate it into English instead. \
            Split the input into individual sentences, keeping punctuation with each sentence. For each sentence, \
            provide the original text and its translation as a pair. Preserve the original meaning, tone, and style.
            """
        }
    }
}
