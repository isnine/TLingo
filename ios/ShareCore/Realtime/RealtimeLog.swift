#if os(macOS) || os(iOS)
    import Foundation
    import os

    /// Realtime conversation diagnostics. Every line starts with `[RT][<stage>]` so Console and
    /// Xcode can filter the whole pipeline with `[RT]`, or one stage such as `[RT][tx]`.
    ///
    /// Stages: session, audio, asr, fluid, src, tx, align, caption, broadcast.
    enum RealtimeLog {
        private static let logger = Logger(subsystem: "com.zanderwang.AITranslator", category: "Realtime")

        static func log(_ stage: String, _ message: String) {
            logger.notice("[RT][\(stage, privacy: .public)] \(message, privacy: .public)")
        }

        static func warn(_ stage: String, _ message: String) {
            logger.warning("[RT][\(stage, privacy: .public)] WARN \(message, privacy: .public)")
        }

        /// Quoted preview plus length. Release builds record only the length so speech content
        /// does not leave the device through sysdiagnose.
        static func text(_ text: String, limit: Int = 48) -> String {
            let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            #if DEBUG
                let preview = normalized.count > limit ? "\(normalized.prefix(limit))…" : normalized
                return "\"\(preview)\"(\(normalized.count))"
            #else
                return "(\(normalized.count))"
            #endif
        }

        /// Tail of a segment list, e.g. `[3]"foo" [4]"bar"`.
        static func segments(_ segments: [String], tail: Int = 3) -> String {
            guard !segments.isEmpty else { return "[]" }
            let start = max(0, segments.count - tail)
            return segments[start...].enumerated()
                .map { "[\(start + $0.offset)]\(text($0.element, limit: 32))" }
                .joined(separator: " ")
        }
    }
#endif
