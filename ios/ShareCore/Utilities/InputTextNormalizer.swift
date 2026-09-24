//
//  InputTextNormalizer.swift
//  ShareCore
//

import Foundation

/// Cleans up text copied from code, PDFs, and Apple Books before it is sent for translation.
public enum InputTextNormalizer {
    public static func normalize(_ text: String) -> String {
        var result = removingBooksExcerptInfo(text)
        result = removingCommentMarkers(result)
        result = mergingHardWrappedLines(result)
        result = splittingIdentifier(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removingBooksExcerptInfo(_ text: String) -> String {
        let patterns = [
            #/^“([\s\S]+?)”\s+Excerpt From[\s\S]+This material may be protected by copyright\.$/#,
            #/^“([\s\S]+?)”\s+摘录来自[\s\S]+此材料(?:可能)?受版权保护。$/#,
        ]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in patterns {
            if let match = trimmed.wholeMatch(of: pattern) {
                return String(match.1)
            }
        }
        return text
    }

    static func removingCommentMarkers(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let contentLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !contentLines.isEmpty else { return text }

        let trimmedFirst = contentLines[0].trimmingCharacters(in: .whitespaces)
        let isBlockComment = trimmedFirst.hasPrefix("/*")
        let markers: [String]
        if isBlockComment {
            markers = ["/**", "/*", "*/", "*"]
        } else if contentLines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }) {
            markers = ["///", "//"]
        } else if contentLines.count > 1,
                  contentLines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") })
        {
            markers = ["#"]
        } else {
            return text
        }

        return lines.map { line -> String in
            var stripped = line.trimmingCharacters(in: .whitespaces)
            if isBlockComment, stripped.hasSuffix("*/") {
                stripped = String(stripped.dropLast(2))
            }
            if let marker = markers.first(where: { stripped.hasPrefix($0) }) {
                stripped = String(stripped.dropFirst(marker.count))
            }
            return stripped.trimmingCharacters(in: .whitespaces)
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Joins lines broken mid-sentence, e.g. text copied from PDFs or wrapped code comments.
    static func mergingHardWrappedLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1 else { return text }

        var result = lines[0]
        for line in lines.dropFirst() {
            let next = line.trimmingCharacters(in: .whitespaces)
            let previous = result.trimmingCharacters(in: .whitespaces).last
            let continues = previous.map { $0.isLetter || $0.isNumber || $0 == "," || $0 == "-" } ?? false
            if continues, let first = next.first, first.isLowercase {
                if result.hasSuffix("-"), result.dropLast().last?.isLetter == true {
                    result.removeLast()
                    result += next
                } else {
                    result = result.trimmingCharacters(in: .whitespaces) + " " + next
                }
            } else {
                result += "\n" + line
            }
        }
        return result
    }

    /// Splits a single `snake_case` or multi-part `camelCase` identifier into words.
    /// Two-part names such as `iPhone` or `JavaScript` are kept as brand names.
    static func splittingIdentifier(_ text: String) -> String {
        guard text.wholeMatch(of: #/[A-Za-z][A-Za-z0-9_]*/#) != nil else { return text }

        let parts = text
            .replacing(#/_+/#, with: " ")
            .replacing(#/([a-z0-9])([A-Z])/#) { "\($0.1) \($0.2)" }
            .replacing(#/([A-Z]+)([A-Z][a-z])/#) { "\($0.1) \($0.2)" }
            .split(separator: " ")
        guard text.contains("_") || parts.count >= 3 else { return text }
        return parts
            .map { $0.allSatisfy(\.isUppercase) ? String($0) : $0.lowercased() }
            .joined(separator: " ")
    }
}
