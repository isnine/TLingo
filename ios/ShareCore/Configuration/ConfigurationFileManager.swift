//
//  ConfigurationFileManager.swift
//  ShareCore
//
//  Created by AI Assistant on 2025/12/31.
//

import Combine
import Foundation
import os

/// Notification posted when a configuration file changes externally
public extension Notification.Name {
    static let configurationFileDidChange = Notification.Name("configurationFileDidChange")
}

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "ConfigFileManager")

/// Manages multiple configuration files stored in Application Support (or iCloud)
public final class ConfigurationFileManager: @unchecked Sendable {
    public static let shared = ConfigurationFileManager()

    private let fileManager: FileManager
    private let configurationsDirectoryOverride: URL?

    /// Tracks directories we've already verified exist to avoid repeated filesystem checks
    private var ensuredDirectories: Set<String> = []

    /// App Group identifier for shared container
    private static let appGroupIdentifier = AppPreferences.appGroupSuiteName

    /// File monitoring sources keyed by file URL
    private var fileSources: [URL: DispatchSourceFileSystemObject] = [:]

    /// Lock for thread-safe access to fileSources
    private let sourcesLock = NSLock()

    /// Publisher for file change events
    public let fileChangePublisher = PassthroughSubject<ConfigurationFileChangeEvent, Never>()

    /// Directory where configuration files are stored
    /// Priority: iCloud > App Group (iOS) > Application Support > tmp
    public var configurationsDirectory: URL {
        if let configurationsDirectoryOverride {
            ensureDirectoryExists(configurationsDirectoryOverride)
            return configurationsDirectoryOverride
        }

        // 1. Check if iCloud is enabled and available
        if AppPreferences.shared.useICloudForConfig,
           let iCloudURL = AppPreferences.iCloudDocumentsURL
        {
            let configDir = iCloudURL.appendingPathComponent("Tree2Lang", isDirectory: true)
            ensureDirectoryExists(configDir)
            return configDir
        }

        // 2. [iOS] App Group shared container — both app and extension share this directory.
        //    On macOS we avoid containerURL() because it triggers the "Access Data from Other Apps" dialog.
        #if os(iOS)
            if let groupContainer = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
            ) {
                let configDir = groupContainer.appendingPathComponent("Configurations", isDirectory: true)
                ensureDirectoryExists(configDir)
                return configDir
            }
        #endif

        // 3. Application Support (macOS primary, iOS fallback)
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let tempConfigDir = tempRoot.appendingPathComponent("AITranslator", isDirectory: true)
                .appendingPathComponent("Configurations", isDirectory: true)
            ensureDirectoryExists(tempConfigDir)
            return tempConfigDir
        }
        let configDir = appSupport.appendingPathComponent("Configurations", isDirectory: true)
        ensureDirectoryExists(configDir)
        return configDir
    }

    /// Returns the current storage location type
    public var currentStorageLocation: StorageLocation {
        if AppPreferences.shared.useICloudForConfig && AppPreferences.iCloudDocumentsURL != nil {
            return .iCloud
        }
        return .local
    }

    /// Storage location types
    public enum StorageLocation: String, CaseIterable {
        case local = "Local"
        case iCloud = "iCloud Drive"

        public var description: String {
            switch self {
            case .local:
                return String(localized: "Stored in app container")
            case .iCloud:
                return String(localized: "Synced across devices")
            }
        }

        public var icon: String {
            switch self {
            case .local:
                return "folder.fill"
            case .iCloud:
                return "icloud.fill"
            }
        }
    }

    private func ensureDirectoryExists(_ url: URL) {
        let path = url.path
        guard !ensuredDirectories.contains(path) else { return }
        if !fileManager.fileExists(atPath: path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        ensuredDirectories.insert(path)
    }

    /// Locates the bundled DefaultConfiguration.json, searching ShareCore's bundle first then main.
    public static func bundledDefaultConfigURL() -> URL? {
        let bundles = [
            Bundle(for: ConfigurationFileManager.self),
            Bundle.main,
        ]
        for bundle in bundles {
            if let url = bundle.url(forResource: "DefaultConfiguration", withExtension: "json") {
                return url
            }
        }
        return nil
    }

    /// Copy the bundled default configuration to the configurations directory if it doesn't exist
    /// - Parameter name: The name for the configuration file (without .json extension)
    /// - Returns: true if configuration already exists or was successfully copied
    @discardableResult
    public func copyBundledDefaultIfNeeded(to name: String) -> Bool {
        guard !configurationExists(named: name) else {
            return true
        }

        guard let bundledURL = Self.bundledDefaultConfigURL() else {
            logger.error("Bundled default config not found in any bundle")
            return false
        }

        let sanitizedName = Self.sanitizeFilename(name)
        let targetURL = configurationsDirectory.appendingPathComponent("\(sanitizedName).json")

        do {
            ensureDirectoryExists(configurationsDirectory)
            try fileManager.copyItem(at: bundledURL, to: targetURL)
            logger.info("Copied bundled default to '\(name, privacy: .public).json'")
            return true
        } catch {
            logger.error("Failed to copy bundled config: \(error, privacy: .public)")
            return false
        }
    }

    init(
        fileManager: FileManager = .default,
        configurationsDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        configurationsDirectoryOverride = configurationsDirectory
    }

    /// List all saved configuration files
    public func listConfigurations() -> [ConfigurationFileInfo] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: configurationsDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ConfigurationFileInfo? in
                let name = url.deletingPathExtension().lastPathComponent
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                let modifiedDate = attributes?[.modificationDate] as? Date ?? Date()
                return ConfigurationFileInfo(name: name, url: url, modifiedDate: modifiedDate)
            }
            .sorted { $0.modifiedDate > $1.modifiedDate }
    }

    /// Save a configuration with the given name
    public func saveConfiguration(
        _ config: AppConfiguration,
        name: String
    ) throws {
        let sanitizedName = Self.sanitizeFilename(name)
        let fileURL = configurationsDirectory.appendingPathComponent("\(sanitizedName).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Load a configuration from the given URL
    public func loadConfiguration(from url: URL) throws -> AppConfiguration {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(AppConfiguration.self, from: data)
    }

    /// Load a configuration by name
    public func loadConfiguration(named name: String) throws -> AppConfiguration {
        let sanitizedName = Self.sanitizeFilename(name)
        let fileURL = configurationsDirectory.appendingPathComponent("\(sanitizedName).json")
        logger
            .debug(
                "loadConfiguration(named: '\(name, privacy: .public)') → \(fileURL.path, privacy: .public), exists: \(self.fileManager.fileExists(atPath: fileURL.path), privacy: .public)"
            )
        return try loadConfiguration(from: fileURL)
    }

    /// Delete a configuration file
    public func deleteConfiguration(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    /// Delete a configuration by name
    public func deleteConfiguration(named name: String) throws {
        let sanitizedName = Self.sanitizeFilename(name)
        let fileURL = configurationsDirectory.appendingPathComponent("\(sanitizedName).json")
        try fileManager.removeItem(at: fileURL)
    }

    /// Create and save the default configuration template
    @MainActor
    public func createDefaultTemplate(
        from store: AppConfigurationStore,
        preferences: AppPreferences
    ) throws -> URL {
        guard let data = ConfigurationService.shared.exportConfiguration(
            from: store,
            preferences: preferences
        ) else {
            throw ConfigurationError.invalidData
        }

        let config = try JSONDecoder().decode(AppConfiguration.self, from: data)
        let name = generateUniqueName(base: "Default Template")
        try saveConfiguration(config, name: name)

        return configurationsDirectory.appendingPathComponent("\(Self.sanitizeFilename(name)).json")
    }

    /// Duplicate an existing configuration with a new name
    public func duplicateConfiguration(from sourceURL: URL) throws -> URL {
        let sourceConfig = try loadConfiguration(from: sourceURL)
        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let newName = generateUniqueName(base: "\(sourceName) Copy")
        try saveConfiguration(sourceConfig, name: newName)
        return configurationsDirectory.appendingPathComponent("\(Self.sanitizeFilename(newName)).json")
    }

    /// Create a new configuration from the bundled default template
    public func createFromDefaultTemplate() throws -> URL {
        guard let bundleURL = Self.bundledDefaultConfigURL() else {
            throw ConfigurationError.bundledConfigNotFound
        }

        // Load the bundled configuration
        let bundledConfig = try loadConfiguration(from: bundleURL)

        // Generate a unique name
        let name = generateUniqueName(base: "New Configuration")
        try saveConfiguration(bundledConfig, name: name)

        return configurationsDirectory.appendingPathComponent("\(Self.sanitizeFilename(name)).json")
    }

    /// Generate a unique name if the base name already exists
    private func generateUniqueName(base: String) -> String {
        let existingNames = Set(listConfigurations().map { $0.name })

        if !existingNames.contains(base) {
            return base
        }

        var counter = 1
        var candidate = "\(base) \(counter)"
        while existingNames.contains(candidate) {
            counter += 1
            candidate = "\(base) \(counter)"
        }

        return candidate
    }

    /// Sanitize a filename to remove invalid characters
    public static func sanitizeFilename(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return name
            .components(separatedBy: invalidCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Configuration File Info

public struct ConfigurationFileInfo: Identifiable, Sendable {
    public let id: URL
    public let name: String
    public let url: URL
    public let modifiedDate: Date

    public init(name: String, url: URL, modifiedDate: Date) {
        id = url
        self.name = name
        self.url = url
        self.modifiedDate = modifiedDate
    }

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    public var formattedDate: String {
        Self.dateFormatter.localizedString(for: modifiedDate, relativeTo: Date())
    }
}

// MARK: - File Change Event

/// Represents a file change event for configuration files
public struct ConfigurationFileChangeEvent: Sendable {
    public enum ChangeType: Sendable {
        case modified
        case deleted
        case renamed
    }

    public let name: String
    public let url: URL
    public let changeType: ChangeType
    public let timestamp: Date

    public init(name: String, url: URL, changeType: ChangeType, timestamp: Date = Date()) {
        self.name = name
        self.url = url
        self.changeType = changeType
        self.timestamp = timestamp
    }
}

// MARK: - File Monitoring Extension

public extension ConfigurationFileManager {
    /// Start monitoring a configuration file for external changes
    func startMonitoring(configurationNamed name: String) {
        let sanitizedName = Self.sanitizeFilename(name)
        let fileURL = configurationsDirectory.appendingPathComponent("\(sanitizedName).json")
        startMonitoring(url: fileURL)
    }

    /// Start monitoring a file URL for changes
    func startMonitoring(url: URL) {
        sourcesLock.lock()
        defer { sourcesLock.unlock() }
        startMonitoringLocked(url: url)
    }

    private func startMonitoringLocked(url: URL) {
        // Don't monitor if already monitoring
        guard fileSources[url] == nil else { return }

        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logger.error("Failed to open file for monitoring: \(url.path, privacy: .public)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let flags = source.data
            let name = url.deletingPathExtension().lastPathComponent

            self.sourcesLock.lock()
            guard self.fileSources[url] === source else {
                self.sourcesLock.unlock()
                return
            }

            let changeType: ConfigurationFileChangeEvent.ChangeType
            if flags.contains(.delete) || flags.contains(.rename) {
                self.fileSources.removeValue(forKey: url)
                source.cancel()
                if self.fileManager.fileExists(atPath: url.path) {
                    // Atomic saves replace the inode while keeping the configuration path.
                    self.startMonitoringLocked(url: url)
                    changeType = .modified
                } else {
                    changeType = flags.contains(.delete) ? .deleted : .renamed
                }
            } else {
                changeType = .modified
            }
            self.sourcesLock.unlock()

            let event = ConfigurationFileChangeEvent(name: name, url: url, changeType: changeType)

            // Publish the event
            self.fileChangePublisher.send(event)

            // Also post a notification for backward compatibility
            NotificationCenter.default.post(
                name: .configurationFileDidChange,
                object: self,
                userInfo: ["event": event]
            )
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        fileSources[url] = source
        source.resume()

        logger.debug("Started monitoring: \(url.lastPathComponent, privacy: .public)")
    }

    /// Stop monitoring a specific file
    func stopMonitoring(url: URL) {
        sourcesLock.lock()
        defer { sourcesLock.unlock() }

        if let source = fileSources.removeValue(forKey: url) {
            source.cancel()
            logger.debug("Stopped monitoring: \(url.lastPathComponent, privacy: .public)")
        }
    }

    /// Stop monitoring a configuration by name
    func stopMonitoring(configurationNamed name: String) {
        let sanitizedName = Self.sanitizeFilename(name)
        let fileURL = configurationsDirectory.appendingPathComponent("\(sanitizedName).json")
        stopMonitoring(url: fileURL)
    }

    /// Stop all file monitoring
    func stopAllMonitoring() {
        sourcesLock.lock()
        defer { sourcesLock.unlock() }

        for (_, source) in fileSources {
            source.cancel()
        }
        fileSources.removeAll()

        logger.debug("Stopped all file monitoring")
    }

    /// Check if a file is being monitored
    func isMonitoring(url: URL) -> Bool {
        sourcesLock.lock()
        defer { sourcesLock.unlock() }
        return fileSources[url] != nil
    }

    /// Get the file URL for a configuration name
    func configurationURL(forName name: String) -> URL {
        let sanitizedName = Self.sanitizeFilename(name)
        return configurationsDirectory.appendingPathComponent("\(sanitizedName).json")
    }

    /// Check if a configuration file exists
    func configurationExists(named name: String) -> Bool {
        let url = configurationURL(forName: name)
        return fileManager.fileExists(atPath: url.path)
    }

    /// Get the modification date of a configuration file
    func modificationDate(forName name: String) -> Date? {
        let url = configurationURL(forName: name)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}
