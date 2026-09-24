//
//  WordLookupDetector.swift
//  ShareCore
//

import Foundation

/// Decides whether input is a word or short phrase that deserves a dictionary-style answer.
public enum WordLookupDetector {
    public static func isWordOrPhrase(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40, !trimmed.contains("\n") else { return false }

        if trimmed.wholeMatch(of: #/[\p{Han}\p{Hiragana}\p{Katakana}ー]{1,4}/#) != nil {
            return true
        }

        let tokens = trimmed.split(separator: " ")
        return tokens.count <= 3 && tokens.allSatisfy { $0.wholeMatch(of: #/\p{L}[\p{Ll}'’-]*/#) != nil }
    }
}
