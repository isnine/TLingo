//
//  RealtimeCaptionDisplay.swift
//  ShareCore
//

import Foundation

public struct RealtimeCaptionLine: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case source
        case translation
    }

    public let id: String
    public let kind: Kind
    public let text: String
    public let isPending: Bool

    public init(id: String, kind: Kind, text: String, isPending: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.isPending = isPending
    }
}

public struct RealtimeCaptionDisplayClearAnchor: Equatable, Sendable {
    public static let empty = RealtimeCaptionDisplayClearAnchor(lines: [])

    public let lines: [RealtimeCaptionLine]

    public var isEmpty: Bool {
        lines.isEmpty
    }

    public init(lines: [RealtimeCaptionLine]) {
        self.lines = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public enum RealtimeCaptionDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case sourceOnly
    case translationOnly
    case bilingual

    public var id: String { rawValue }

    public var next: RealtimeCaptionDisplayMode {
        let modes = Self.allCases
        guard let index = modes.firstIndex(of: self) else { return .bilingual }
        return modes[(index + 1) % modes.count]
    }

    public var systemImageName: String {
        switch self {
        case .sourceOnly:
            return "quote.bubble"
        case .translationOnly:
            return "quote.bubble"
        case .bilingual:
            return "translate"
        }
    }

    public func buttonTitle(sourceLanguageName: String, targetLanguageName: String) -> String? {
        switch self {
        case .sourceOnly:
            return sourceLanguageName
        case .translationOnly:
            return targetLanguageName
        case .bilingual:
            return nil
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .sourceOnly:
            return String(localized: "Source captions only")
        case .translationOnly:
            return String(localized: "Translated captions only")
        case .bilingual:
            return String(localized: "Bilingual captions")
        }
    }

    func includes(_ kind: RealtimeCaptionLine.Kind) -> Bool {
        switch self {
        case .sourceOnly:
            return kind == .source
        case .translationOnly:
            return kind == .translation
        case .bilingual:
            return true
        }
    }
}

public enum RealtimeCaptionDisplay {
    public static func emptyPlaceholderText(isRunning: Bool) -> String {
        isRunning ? String(localized: "Listening...") : String(localized: "Live captions will appear here.")
    }

    public static func linesVisibleAfterClear(
        _ lines: [RealtimeCaptionLine],
        anchor: RealtimeCaptionDisplayClearAnchor
    ) -> [RealtimeCaptionLine] {
        guard !anchor.isEmpty else { return lines }

        var remainingClearedLines = anchor.lines
        return lines.compactMap { line in
            guard let matchIndex = clearAnchorMatchIndex(for: line, in: remainingClearedLines) else {
                return line
            }

            let clearedLine = remainingClearedLines.remove(at: matchIndex)
            guard let suffix = visibleSuffix(in: line.text, afterClearing: clearedLine.text), !suffix.isEmpty else {
                return nil
            }

            return RealtimeCaptionLine(
                id: line.id,
                kind: line.kind,
                text: suffix,
                isPending: line.isPending
            )
        }
    }

    public static func displayWindow(
        _ lines: [RealtimeCaptionLine],
        limit: Int
    ) -> [RealtimeCaptionLine] {
        guard limit > 0, lines.count > limit else { return lines }
        return Array(lines.suffix(limit))
    }

    public static func resolvedLines(
        pairs: [SentencePair],
        translatedSource: String,
        translatedText: String,
        pendingSource: String,
        pendingTranslation: String,
        sourceText: String,
        mode: RealtimeCaptionDisplayMode,
        showsUntranslatedSource: Bool = true
    ) -> [RealtimeCaptionLine] {
        resolvedLines(
            pairs: pairs,
            translatedSourceSegments: sourceSegments(from: translatedSource),
            translatedSource: translatedSource,
            translatedText: translatedText,
            pendingSource: pendingSource,
            pendingTranslation: pendingTranslation,
            sourceText: sourceText,
            mode: mode,
            showsUntranslatedSource: showsUntranslatedSource
        )
    }

    public static func resolvedLines(
        pairs: [SentencePair],
        translatedSourceSegments: [String],
        translatedSource: String,
        translatedText: String,
        pendingSource: String,
        pendingTranslation: String,
        sourceText: String,
        mode: RealtimeCaptionDisplayMode,
        showsUntranslatedSource: Bool = true
    ) -> [RealtimeCaptionLine] {
        let pairedLines = lines(
            from: pairs,
            translatedSourceSegments: translatedSourceSegments,
            translatedSource: translatedSource,
            translatedText: translatedText,
            pendingSource: pendingSource,
            pendingTranslation: pendingTranslation,
            mode: mode,
            showsUntranslatedSource: showsUntranslatedSource
        )
        if !pairedLines.isEmpty {
            return pairedLines
        }
        return filteredLines(
            fallbackLines(
                sourceText: sourceText,
                translatedText: translatedText,
                showsUntranslatedSource: showsUntranslatedSource
            ),
            mode: mode
        )
    }

    static func untranslatedSourceSignature(
        pairs: [SentencePair],
        translatedSource: String,
        translatedText: String,
        pendingSource: String,
        pendingTranslation: String,
        sourceText: String
    ) -> String? {
        untranslatedSourceSignature(
            pairs: pairs,
            translatedSourceSegments: sourceSegments(from: translatedSource),
            translatedSource: translatedSource,
            translatedText: translatedText,
            pendingSource: pendingSource,
            pendingTranslation: pendingTranslation,
            sourceText: sourceText
        )
    }

    static func untranslatedSourceSignature(
        pairs: [SentencePair],
        translatedSourceSegments: [String],
        translatedSource: String,
        translatedText: String,
        pendingSource: String,
        pendingTranslation: String,
        sourceText: String
    ) -> String? {
        let sources = untranslatedSourceTexts(
            pairs: pairs,
            translatedSourceSegments: translatedSourceSegments,
            translatedSource: translatedSource,
            translatedText: translatedText,
            pendingSource: pendingSource,
            pendingTranslation: pendingTranslation,
            sourceText: sourceText
        )
        let signature = sources
            .map { normalized($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return signature.isEmpty ? nil : signature
    }

    static func recentUntranslatedSourceSignature(
        pairs: [SentencePair],
        translatedSourceSegments: [String],
        translatedText: String,
        pendingSource: String,
        pendingTranslation: String,
        sourceText: String,
        segmentLimit: Int
    ) -> String? {
        let limitedSegments = segmentLimit > 0
            ? Array(translatedSourceSegments.suffix(segmentLimit))
            : translatedSourceSegments
        let limitedPairs = segmentLimit > 0
            ? Array(pairs.suffix(segmentLimit * 2))
            : pairs
        return untranslatedSourceSignature(
            pairs: limitedPairs,
            translatedSourceSegments: limitedSegments,
            translatedSource: limitedSegments.joined(separator: "\n\n"),
            translatedText: translatedText,
            pendingSource: pendingSource,
            pendingTranslation: pendingTranslation,
            sourceText: sourceText
        )
    }

    private static func fallbackLines(
        sourceText: String,
        translatedText: String,
        showsUntranslatedSource: Bool
    ) -> [RealtimeCaptionLine] {
        let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [RealtimeCaptionLine] = []
        if !source.isEmpty, showsUntranslatedSource || !translation.isEmpty {
            lines.append(contentsOf: sourceLines(from: source, idPrefix: "fallback-source"))
        }
        if !translation.isEmpty {
            lines.append(RealtimeCaptionLine(id: "fallback-translation", kind: .translation, text: translation))
        }
        return lines
    }

    public static func lines(
        from pairs: [SentencePair],
        translatedSource: String = "",
        translatedText: String = "",
        pendingSource: String = "",
        pendingTranslation: String = "",
        mode: RealtimeCaptionDisplayMode = .bilingual,
        showsUntranslatedSource: Bool = true
    ) -> [RealtimeCaptionLine] {
        lines(
            from: pairs,
            translatedSourceSegments: sourceSegments(from: translatedSource),
            translatedSource: translatedSource,
            translatedText: translatedText,
            pendingSource: pendingSource,
            pendingTranslation: pendingTranslation,
            mode: mode,
            showsUntranslatedSource: showsUntranslatedSource
        )
    }

    public static func lines(
        from pairs: [SentencePair],
        translatedSourceSegments: [String],
        translatedSource: String = "",
        translatedText: String = "",
        pendingSource: String = "",
        pendingTranslation: String = "",
        mode: RealtimeCaptionDisplayMode = .bilingual,
        showsUntranslatedSource: Bool = true
    ) -> [RealtimeCaptionLine] {
        if pairs.isEmpty {
            let plainTranslationLines = plainTranslationLines(
                translatedSourceSegments: translatedSourceSegments,
                translatedSource: translatedSource,
                translatedText: translatedText,
                pendingSource: pendingSource,
                pendingTranslation: pendingTranslation,
                showsUntranslatedSource: showsUntranslatedSource
            )
            if !plainTranslationLines.isEmpty {
                return filteredLines(plainTranslationLines, mode: mode)
            }
        }

        let sourceAlignedLines = sourceAlignedLines(
            from: pairs,
            sourceSegments: translatedSourceSegments,
            showsUntranslatedSource: showsUntranslatedSource
        )

        let pending = pendingSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingTranslated = pendingTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = sourceAlignedLines
        appendPreviousTranslationIfNeeded(
            to: &lines,
            translatedText: translatedText
        )
        if !pending.isEmpty, showsUntranslatedSource || !pendingTranslated.isEmpty {
            lines.append(RealtimeCaptionLine(id: "pending-source", kind: .source, text: pending, isPending: true))
        }
        if !pendingTranslated.isEmpty {
            lines.append(RealtimeCaptionLine(
                id: "pending-translation",
                kind: .translation,
                text: pendingTranslated,
                isPending: true
            ))
        }
        return filteredLines(lines, mode: mode)
    }

    public static func filteredLines(
        _ lines: [RealtimeCaptionLine],
        mode: RealtimeCaptionDisplayMode
    ) -> [RealtimeCaptionLine] {
        let filtered = lines.filter { mode.includes($0.kind) }
        if filtered.isEmpty, mode == .translationOnly {
            return lines.filter { $0.kind == .source && $0.isPending }
        }
        return filtered
    }

    private static func sourceSegments(from text: String) -> [String] {
        RealtimeTranscriptSegmenter.segments(from: text)
    }

    private static func plainTranslationLines(
        translatedSourceSegments: [String],
        translatedSource: String,
        translatedText: String,
        pendingSource: String,
        pendingTranslation: String,
        showsUntranslatedSource: Bool
    ) -> [RealtimeCaptionLine] {
        let source = translatedSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = pendingSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingTranslated = pendingTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [RealtimeCaptionLine] = []
        if !source.isEmpty, showsUntranslatedSource || !translation.isEmpty {
            lines.append(contentsOf: sourceLines(from: translatedSourceSegments, fallback: source, idPrefix: "plain-source"))
        }
        if !translation.isEmpty {
            lines.append(RealtimeCaptionLine(id: "plain-translation", kind: .translation, text: translation))
        }
        if !pending.isEmpty, showsUntranslatedSource || !pendingTranslated.isEmpty {
            lines.append(RealtimeCaptionLine(id: "pending-source", kind: .source, text: pending, isPending: true))
        }
        if !pendingTranslated.isEmpty {
            lines.append(RealtimeCaptionLine(
                id: "pending-translation",
                kind: .translation,
                text: pendingTranslated,
                isPending: true
            ))
        }
        return lines
    }

    private static func appendPreviousTranslationIfNeeded(
        to lines: inout [RealtimeCaptionLine],
        translatedText: String
    ) {
        let translations = translationLines(from: translatedText)
        guard !translations.isEmpty else { return }

        let existingTranslations = Set(lines.flatMap { line -> [String] in
            guard line.kind == .translation else { return [] }
            return ([line.text] + translationLines(from: line.text))
                .map { normalized($0) }
                .filter { !$0.isEmpty }
        })
        let missingTranslations = translations.filter { !existingTranslations.contains(normalized($0)) }
        guard !missingTranslations.isEmpty else { return }

        for (index, translation) in missingTranslations.enumerated() {
            lines.append(RealtimeCaptionLine(id: "previous-translation-\(index)", kind: .translation, text: translation))
        }
    }

    private static func translationLines(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func clearAnchorMatchIndex(
        for line: RealtimeCaptionLine,
        in clearedLines: [RealtimeCaptionLine]
    ) -> Int? {
        if let index = clearedLines.firstIndex(where: { clearedLine in
            clearedLine.kind == line.kind
                && clearedLine.id == line.id
                && visibleSuffix(in: line.text, afterClearing: clearedLine.text) != nil
        }) {
            return index
        }

        if let index = clearedLines.firstIndex(where: { clearedLine in
            clearedLine.kind == line.kind
                && normalized(clearedLine.text) == normalized(line.text)
        }) {
            return index
        }

        return clearedLines.firstIndex { clearedLine in
            clearedLine.kind == line.kind
                && visibleSuffix(in: line.text, afterClearing: clearedLine.text) != nil
        }
    }

    private static func visibleSuffix(in text: String, afterClearing clearedText: String) -> String? {
        let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleared = clearedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleared.isEmpty else { return current }
        guard current.hasPrefix(cleared) else { return nil }

        return String(current.dropFirst(cleared.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sourceAlignedLines(
        from pairs: [SentencePair],
        sourceSegments: [String],
        showsUntranslatedSource: Bool
    ) -> [RealtimeCaptionLine] {
        guard !sourceSegments.isEmpty else {
            return pairs.enumerated().flatMap { index, pair in
                pairedLines(pair, index: index)
            }
        }

        var pairsBySource = Dictionary(grouping: pairs) { normalized($0.original) }
        var lines: [RealtimeCaptionLine] = []
        for (index, source) in sourceSegments.enumerated() {
            let key = normalized(source)
            if var matchingPairs = pairsBySource[key], let pair = matchingPairs.first {
                matchingPairs.removeFirst()
                pairsBySource[key] = matchingPairs
                lines.append(contentsOf: pairedLines(pair, index: index))
            } else if showsUntranslatedSource {
                lines.append(RealtimeCaptionLine(id: "\(index)-source-in-flight", kind: .source, text: source))
            }
        }
        return lines
    }

    private static func untranslatedSourceTexts(
        pairs: [SentencePair],
        translatedSourceSegments: [String],
        translatedSource: String,
        translatedText: String,
        pendingSource: String,
        pendingTranslation: String,
        sourceText: String
    ) -> [String] {
        let pending = pendingSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingTranslated = pendingTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        var sources: [String] = []

        if pairs.isEmpty {
            let source = translatedSource.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !source.isEmpty, translation.isEmpty {
                sources.append(source)
            }
        } else {
            var pairsBySource = Dictionary(grouping: pairs) { normalized($0.original) }
            for source in translatedSourceSegments {
                let key = normalized(source)
                if var matchingPairs = pairsBySource[key], !matchingPairs.isEmpty {
                    matchingPairs.removeFirst()
                    pairsBySource[key] = matchingPairs
                } else {
                    sources.append(source)
                }
            }
        }

        if !pending.isEmpty, pendingTranslated.isEmpty {
            sources.append(pending)
        }

        if sources.isEmpty, translatedSourceSegments.isEmpty, pending.isEmpty {
            let fallbackSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTranslation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallbackSource.isEmpty, fallbackTranslation.isEmpty {
                sources.append(fallbackSource)
            }
        }

        return sources
    }

    private static func pairedLines(_ pair: SentencePair, index: Int) -> [RealtimeCaptionLine] {
        let original = pair.original.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = pair.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [RealtimeCaptionLine] = []
        lines.append(RealtimeCaptionLine(id: "\(index)-source", kind: .source, text: original))
        lines.append(RealtimeCaptionLine(id: "\(index)-translation", kind: .translation, text: translation))
        return lines.filter { !$0.text.isEmpty }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func sourceLines(from text: String, idPrefix: String) -> [RealtimeCaptionLine] {
        let segments = sourceSegments(from: text)
        return sourceLines(from: segments, fallback: text, idPrefix: idPrefix)
    }

    private static func sourceLines(from segments: [String], fallback _: String, idPrefix: String) -> [RealtimeCaptionLine] {
        guard !segments.isEmpty else { return [] }
        if segments.count == 1, let segment = segments.first {
            return [RealtimeCaptionLine(id: idPrefix, kind: .source, text: segment)]
        }
        return segments.enumerated().map { index, segment in
            RealtimeCaptionLine(id: "\(idPrefix)-\(index)", kind: .source, text: segment)
        }
    }
}
