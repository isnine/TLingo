//
//  RealtimeHistoryAudioStorage.swift
//  ShareCore
//

import Foundation
import os

public enum RealtimeHistoryAudioStorage {
    private static let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "RealtimeHistoryAudio")

    public static func rootURL(fileManager: FileManager = .default) -> URL? {
        #if os(macOS)
            guard let appSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                return nil
            }
            return appSupport
                .appendingPathComponent("History", isDirectory: true)
                .appendingPathComponent("RealtimeAudio", isDirectory: true)
        #else
            guard let groupContainer = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: AppPreferences.appGroupSuiteName
            ) else {
                return nil
            }
            return groupContainer
                .appendingPathComponent("History", isDirectory: true)
                .appendingPathComponent("RealtimeAudio", isDirectory: true)
        #endif
    }

    public static func fileURL(for segment: RealtimeHistoryAudioSegment, fileManager: FileManager = .default) -> URL? {
        fileURL(relativePath: segment.relativePath, fileManager: fileManager)
    }

    public static func fileURL(relativePath: String, fileManager: FileManager = .default) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains(".."),
              let rootURL = rootURL(fileManager: fileManager)
        else {
            return nil
        }
        return rootURL.appendingPathComponent(relativePath, isDirectory: false)
    }

    static func directoryURL(for directoryName: String, fileManager: FileManager = .default) -> URL? {
        guard !directoryName.isEmpty,
              !directoryName.hasPrefix("/"),
              !directoryName.contains(".."),
              let rootURL = rootURL(fileManager: fileManager)
        else {
            return nil
        }
        return rootURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func deleteRecording(_ recording: RealtimeHistoryAudioRecording?, fileManager: FileManager = .default) {
        guard let recording,
              let directoryURL = directoryURL(for: recording.directoryName, fileManager: fileManager)
        else {
            return
        }
        do {
            try fileManager.removeItem(at: directoryURL)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            let message = error.localizedDescription
            logger.error(
                "Recording deletion failed path=\(directoryURL.path, privacy: .private) error=\(message, privacy: .public)"
            )
        }
    }

    static func deleteRecordings(_ recordings: [RealtimeHistoryAudioRecording], fileManager: FileManager = .default) {
        recordings.forEach { deleteRecording($0, fileManager: fileManager) }
    }

    /// Directories touched within this window may belong to a recording that is still in progress
    /// (or one from another process) and has not been referenced by a history record yet.
    static let pruneGracePeriod: TimeInterval = 24 * 60 * 60

    static func pruneUnreferencedRecordings(
        referencedDirectoryNames: Set<String>,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) {
        guard let rootURL = rootURL(fileManager: fileManager),
              let contents = try? fileManager.contentsOfDirectory(
                  at: rootURL,
                  includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              )
        else {
            return
        }

        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true,
                  !referencedDirectoryNames.contains(url.lastPathComponent)
            else {
                continue
            }
            if let modified = values?.contentModificationDate,
               now.timeIntervalSince(modified) < pruneGracePeriod
            {
                continue
            }
            do {
                try fileManager.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                let message = error.localizedDescription
                logger.error(
                    "Recording prune failed path=\(url.path, privacy: .private) error=\(message, privacy: .public)"
                )
            }
        }
    }
}
