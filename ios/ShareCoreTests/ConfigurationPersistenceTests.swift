//
//  ConfigurationPersistenceTests.swift
//  ShareCoreTests
//

import Combine
import Foundation
@testable import ShareCore
import Testing

@Suite("Configuration persistence")
struct ConfigurationPersistenceTests {
    @MainActor
    @Test("Store restores the persisted active configuration")
    func restoresPersistedActiveConfiguration() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.manager.saveConfiguration(
            AppConfiguration(actions: [
                .init(name: "Fallback Action", prompt: "Fallback"),
            ]),
            name: "Configuration"
        )
        try harness.manager.saveConfiguration(
            AppConfiguration(actions: [
                .init(name: "Restored Action", prompt: "Restored"),
            ]),
            name: "Work"
        )
        harness.preferences.setCurrentConfigName("Work")

        let store = AppConfigurationStore(
            preferences: harness.preferences,
            configFileManager: harness.manager
        )

        #expect(store.currentConfigurationName == "Work")
        #expect(store.customActions.map(\.name) == ["Restored Action"])
    }

    @MainActor
    @Test("Store safely falls back when the persisted configuration is missing")
    func fallsBackWhenPersistedConfigurationIsMissing() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        try harness.manager.saveConfiguration(
            AppConfiguration(actions: [
                .init(name: "Fallback Action", prompt: "Fallback"),
            ]),
            name: "Configuration"
        )
        harness.preferences.setCurrentConfigName("Missing")

        let store = AppConfigurationStore(
            preferences: harness.preferences,
            configFileManager: harness.manager
        )

        #expect(store.currentConfigurationName == "Configuration")
        #expect(store.customActions.map(\.name) == ["Fallback Action"])
        #expect(harness.preferences.currentConfigName == "Configuration")
    }

    @Test("Configuration files round-trip through an atomic save")
    func configurationFilesRoundTripAtomically() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }
        let config = AppConfiguration(actions: [
            .init(name: "Custom", prompt: "Prompt"),
        ])

        try harness.manager.saveConfiguration(config, name: "Atomic")
        let loaded = try harness.manager.loadConfiguration(named: "Atomic")

        #expect(loaded.actions.map(\.name) == ["Custom"])
        #expect(loaded.actions.map(\.prompt) == ["Prompt"])
    }

    @Test("Monitoring survives repeated atomic configuration saves")
    func monitoringSurvivesAtomicSaves() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }
        let events = FileChangeEvents()
        let subscription = harness.manager.fileChangePublisher.sink { events.append($0) }
        defer { subscription.cancel() }

        try harness.manager.saveConfiguration(AppConfiguration(actions: []), name: "Atomic")
        harness.manager.startMonitoring(configurationNamed: "Atomic")

        for index in 0 ..< 3 {
            try harness.manager.saveConfiguration(
                AppConfiguration(actions: [.init(name: "Action \(index)", prompt: "Prompt")]),
                name: "Atomic"
            )
            let event = try #require(events.next())
            #expect(event.name == "Atomic")
            #expect(harness.manager.isMonitoring(url: harness.manager.configurationURL(forName: "Atomic")))
            guard case .modified = event.changeType else {
                Issue.record("Atomic replacement must be reported as modification")
                return
            }
        }
    }

    @Test("Deleting a monitored configuration releases its watcher")
    func deletionReleasesWatcher() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }
        let events = FileChangeEvents()
        let subscription = harness.manager.fileChangePublisher.sink { events.append($0) }
        defer { subscription.cancel() }

        try harness.manager.saveConfiguration(AppConfiguration(actions: []), name: "Deleted")
        harness.manager.startMonitoring(configurationNamed: "Deleted")
        try harness.manager.deleteConfiguration(named: "Deleted")
        let event = try #require(events.next())
        guard case .deleted = event.changeType else {
            Issue.record("Removing the path must be reported as deletion")
            return
        }
        #expect(!harness.manager.isMonitoring(url: harness.manager.configurationURL(forName: "Deleted")))

        try harness.manager.saveConfiguration(AppConfiguration(actions: []), name: "Deleted")
        harness.manager.startMonitoring(configurationNamed: "Deleted")
        try harness.manager.saveConfiguration(AppConfiguration(actions: []), name: "Deleted")
        let replacement = try #require(events.next())
        guard case .modified = replacement.changeType else {
            Issue.record("A recreated configuration must support a new watcher")
            return
        }
    }

    @Test("Stopping during atomic replacement does not resurrect a watcher")
    func stoppingDuringReplacementKeepsMonitoringStopped() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }
        let events = FileChangeEvents()
        let subscription = harness.manager.fileChangePublisher.sink { events.append($0) }
        defer { subscription.cancel() }

        try harness.manager.saveConfiguration(AppConfiguration(actions: []), name: "Stopped")
        harness.manager.startMonitoring(configurationNamed: "Stopped")
        try harness.manager.saveConfiguration(AppConfiguration(actions: []), name: "Stopped")
        harness.manager.stopMonitoring(configurationNamed: "Stopped")

        // Let an already accepted event finish before checking future writes.
        while events.next(timeout: 0.2) != nil {}
        #expect(!harness.manager.isMonitoring(url: harness.manager.configurationURL(forName: "Stopped")))
        try harness.manager.saveConfiguration(AppConfiguration(actions: []), name: "Stopped")
        #expect(events.next(timeout: 0.3) == nil)
    }

    @MainActor
    @Test("Store reports configuration save failures")
    func reportsSaveFailure() throws {
        let harness = try TestHarness(blockDirectory: true)
        defer { harness.cleanup() }
        let store = AppConfigurationStore(
            preferences: harness.preferences,
            configFileManager: harness.manager
        )

        switch store.forceSaveConfiguration() {
        case .success:
            Issue.record("Expected the blocked configuration directory to fail")
        case let .failure(error):
            guard case .fileWriteFailed = error else {
                Issue.record("Expected fileWriteFailed, got \(error)")
                return
            }
        }

        let action = ActionConfig(name: "Unsaved", prompt: "Prompt")
        switch store.updateCustomActions([action]) {
        case .success:
            Issue.record("Expected the action update to report the save failure")
        case .failure:
            #expect(store.customActions.isEmpty)
        }
    }
}

private final class FileChangeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private let available = DispatchSemaphore(value: 0)
    private var events: [ConfigurationFileChangeEvent] = []

    func append(_ event: ConfigurationFileChangeEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
        available.signal()
    }

    func next(timeout: TimeInterval = 3) -> ConfigurationFileChangeEvent? {
        guard available.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return events.removeFirst()
    }
}

private final class TestHarness {
    let rootURL: URL
    let defaultsName: String
    let preferences: AppPreferences
    let manager: ConfigurationFileManager

    init(blockDirectory: Bool = false) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigurationPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        defaultsName = "ConfigurationPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        preferences = AppPreferences(defaults: defaults)

        if blockDirectory {
            try Data("blocked".utf8).write(to: rootURL)
        } else {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        manager = ConfigurationFileManager(configurationsDirectory: rootURL)
    }

    func cleanup() {
        manager.stopAllMonitoring()
        try? FileManager.default.removeItem(at: rootURL)
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }
}
