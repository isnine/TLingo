//
//  RealtimeActivityAttributes.swift
//  TLingo
//
//  Compiled into both the TLingo app and TLingoWidgets; keep the two in sync by sharing this file only.
//

#if os(iOS)
    import ActivityKit
    import Foundation

    nonisolated struct RealtimeActivityAttributes: ActivityAttributes {
        struct ContentState: Codable, Hashable {
            /// Latest translated caption; empty until the first translation lands.
            var translation: String
            /// Latest recognized source caption.
            var source: String
            var isPaused: Bool
        }

        /// e.g. "English → 简体中文"
        var languagePair: String
    }
#endif
