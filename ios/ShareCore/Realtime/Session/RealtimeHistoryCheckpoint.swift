//
//  RealtimeHistoryCheckpoint.swift
//  ShareCore
//

import Foundation

public struct RealtimeHistorySnapshot: Equatable {
    public let sourceText: String
    public let translatedText: String
    let checkpointSourceText: String
    let checkpointTranslatedText: String

    public init(sourceText: String, translatedText: String) {
        self.sourceText = sourceText
        self.translatedText = translatedText
        checkpointSourceText = sourceText
        checkpointTranslatedText = translatedText
    }

    init(
        sourceText: String,
        translatedText: String,
        checkpointSourceText: String,
        checkpointTranslatedText: String
    ) {
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.checkpointSourceText = checkpointSourceText
        self.checkpointTranslatedText = checkpointTranslatedText
    }
}

public struct RealtimeHistoryCheckpoint {
    private var savedSourceText: String
    private var savedTranslatedText: String

    public init(savedSourceText: String = "", savedTranslatedText: String = "") {
        self.savedSourceText = savedSourceText
        self.savedTranslatedText = savedTranslatedText
    }

    public func snapshot(sourceText: String, translatedText: String) -> RealtimeHistorySnapshot? {
        let sourceDelta = Self.unsavedText(in: sourceText, after: savedSourceText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let translationDelta = Self.unsavedText(in: translatedText, after: savedTranslatedText)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sourceDelta.isEmpty, !translationDelta.isEmpty else { return nil }

        return RealtimeHistorySnapshot(
            sourceText: sourceDelta,
            translatedText: translationDelta,
            checkpointSourceText: sourceText,
            checkpointTranslatedText: translatedText
        )
    }

    public mutating func acknowledge(_ snapshot: RealtimeHistorySnapshot) {
        savedSourceText = snapshot.checkpointSourceText
        savedTranslatedText = snapshot.checkpointTranslatedText
    }

    public mutating func reset() {
        savedSourceText = ""
        savedTranslatedText = ""
    }

    private static func unsavedText(in currentText: String, after savedText: String) -> String {
        guard !savedText.isEmpty else { return currentText }
        guard currentText.hasPrefix(savedText) else { return currentText }
        return String(currentText.dropFirst(savedText.count))
    }
}
