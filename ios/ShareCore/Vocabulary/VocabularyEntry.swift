//
//  VocabularyEntry.swift
//  ShareCore
//

import Foundation
import SwiftData

/// A saved term and its translation. Stored apart from History so its schema never migrates the History store.
@Model
public final class VocabularyEntry {
    @Attribute(.unique) public var id: UUID
    public var term: String
    /// Deduplication key together with `targetLanguageCode`.
    public var normalizedTerm: String
    /// Markdown as produced by the translation result.
    public var translation: String
    public var sourceLanguageCode: String?
    public var targetLanguageCode: String
    public var createdAt: Date
    public var reviewCount: Int
    /// 0 (new or forgotten) through `VocabularyEntry.learnedFamiliarity`.
    public var familiarity: Int
    public var lastReviewedAt: Date?

    public static let learnedFamiliarity = 5

    public var isLearned: Bool {
        familiarity >= Self.learnedFamiliarity
    }

    init(draft: VocabularyDraft, createdAt: Date = Date()) {
        id = UUID()
        term = draft.term
        normalizedTerm = VocabularyDraft.normalize(draft.term)
        translation = draft.translation
        sourceLanguageCode = draft.sourceLanguageCode
        targetLanguageCode = draft.targetLanguageCode
        self.createdAt = createdAt
        reviewCount = 0
        familiarity = 0
        lastReviewedAt = nil
    }
}

public struct VocabularyDraft: Equatable, Sendable {
    public let term: String
    public let translation: String
    public let sourceLanguageCode: String?
    public let targetLanguageCode: String

    public init(term: String, translation: String, sourceLanguageCode: String?, targetLanguageCode: String) {
        self.term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        self.translation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
    }

    var key: String {
        Self.key(normalizedTerm: Self.normalize(term), targetLanguageCode: targetLanguageCode)
    }

    static func key(normalizedTerm: String, targetLanguageCode: String) -> String {
        "\(targetLanguageCode)|\(normalizedTerm)"
    }

    static func normalize(_ term: String) -> String {
        term
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }
}
