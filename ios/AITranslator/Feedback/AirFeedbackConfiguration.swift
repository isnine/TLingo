import Foundation

/// Public ingestion-only configuration. This key is shipped with the app;
/// it is not an account, management credential, or translation API secret.
nonisolated enum AirFeedbackConfiguration {
    static let appKey = "ak_production_TVLOEnb2B0_g6a8hMfVcdukeMSFtspJ7NmB12l-Z2qk"
    static let feedbackEndpoint = URL(string: "https://apps.air.build/v1/ingest/feedback")!
    static let crashEndpoint = "https://apps.air.build/v1/ingest/crashes"
    static let teamID = "JW2LR94V6G"
    static let bundleID = "com.zanderwang.AITranslator"
    static let maximumImages = 4
    static let maximumMessageLength = 4000

    /// Conservative UTF-16 limit also fits the server's 4000-character cap.
    /// Keep whole user-perceived characters, including composed emoji.
    static func limitedMessage(_ value: String) -> String {
        var count = 0
        return String(value.prefix { character in
            count += String(character).utf16.count
            return count <= maximumMessageLength
        })
    }
}
