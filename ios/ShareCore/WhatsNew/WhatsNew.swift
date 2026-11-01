//
//  WhatsNew.swift
//  ShareCore
//

import Foundation

/// Release notes bundled as `ReleaseNotes.json`, generated from CHANGELOG.md by `scripts/release_notes.py`.
public struct ReleaseNotes: Decodable, Sendable {
    public struct Release: Decodable, Sendable {
        public let version: String
        public let items: [Item]
    }

    public struct Item: Decodable, Sendable, Hashable {
        public enum Kind: String, Decodable, Sendable, CaseIterable {
            case added
            case improved
            case fixed
        }

        public enum Platform: String, Decodable, Sendable {
            case ios
            case macos
        }

        public let kind: Kind
        /// English source text; also the key in `ReleaseNotes.xcstrings`.
        public let text: String
        /// `nil` means every platform.
        public let platforms: [Platform]?

        public var localizedText: String {
            WhatsNew.bundle.localizedString(forKey: text, value: text, table: WhatsNew.table)
        }
    }

    public let releases: [Release]
}

/// What to show for this launch: changes from every version after the last one the user opened.
public struct WhatsNewSummary: Identifiable, Sendable {
    public let previousVersion: String
    public let version: String
    public let missedVersionCount: Int
    public let items: [ReleaseNotes.Item]

    public var id: String { version }
}

public enum WhatsNew {
    static let table = "ReleaseNotes"
    static let maxItems = 8
    private static let lastSeenVersionKey = "whatsNew.lastSeenVersion"
    private final class BundleToken {}
    public static let bundle = Bundle(for: BundleToken.self)

    #if os(macOS)
        static let currentPlatform = ReleaseNotes.Item.Platform.macos
    #else
        static let currentPlatform = ReleaseNotes.Item.Platform.ios
    #endif

    /// Returns the summary to present, or `nil` after recording the current version as seen.
    /// A first launch without a stored version shows the current release only for `isExistingUser`,
    /// so upgraders from builds without this feature still see it while new installs do not.
    public static func pendingSummary(isExistingUser: Bool, defaults: UserDefaults = .standard) -> WhatsNewSummary? {
        guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let releases = loadReleases()
        else { return nil }

        var lastSeen = defaults.string(forKey: lastSeenVersionKey)
        if lastSeen == nil, isExistingUser {
            lastSeen = releases.first { compare($0.version, current) == .orderedAscending }?.version
        }
        guard let lastSeen,
              let summary = summary(lastSeen: lastSeen, current: current, releases: releases, platform: currentPlatform)
        else {
            markSeen(current, defaults: defaults)
            return nil
        }
        return summary
    }

    public static func markSeen(_ version: String, defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: lastSeenVersionKey)
    }

    static func summary(
        lastSeen: String,
        current: String,
        releases: [ReleaseNotes.Release],
        platform: ReleaseNotes.Item.Platform
    ) -> WhatsNewSummary? {
        let missed = releases
            .filter {
                compare(lastSeen, $0.version) == .orderedAscending
                    && compare($0.version, current) != .orderedDescending
            }
            .sorted { compare($0.version, $1.version) == .orderedDescending }
        guard !missed.isEmpty else { return nil }

        var seen = Set<String>()
        let items = missed
            .flatMap(\.items)
            .filter { $0.platforms?.contains(platform) ?? true }
            .filter { seen.insert($0.text).inserted }
        // Group by kind while keeping newest-first order inside each group.
        let grouped = ReleaseNotes.Item.Kind.allCases.flatMap { kind in items.filter { $0.kind == kind } }
        guard !grouped.isEmpty else { return nil }

        return WhatsNewSummary(
            previousVersion: lastSeen,
            version: current,
            missedVersionCount: missed.count,
            items: Array(grouped.prefix(maxItems))
        )
    }

    private static func loadReleases() -> [ReleaseNotes.Release]? {
        guard let url = bundle.url(forResource: table, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(ReleaseNotes.self, from: data).releases
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}
