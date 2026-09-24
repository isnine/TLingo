//
//  OCRTextRecognizer.swift
//  ShareCore
//

import CoreGraphics
import Vision

/// Recognizes text in an image with Vision and merges line observations into paragraphs.
public enum OCRTextRecognizer {
    struct Line: Equatable {
        let text: String
        /// Image pixel coordinates (origin at bottom-left).
        let box: CGRect
    }

    public static func recognizeText(in image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: image)
        let lines = observations.compactMap { observation -> Line? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox.cgRect
            let width = CGFloat(image.width), height = CGFloat(image.height)
            return Line(
                text: text,
                box: CGRect(x: box.minX * width, y: box.minY * height, width: box.width * width, height: box.height * height)
            )
        }
        return mergeLines(lines)
    }

    /// Joins wrapped lines and starts a new paragraph on large vertical gaps or indentation.
    static func mergeLines(_ lines: [Line]) -> String {
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        guard let first = sorted.first else { return "" }

        let heights = sorted.map(\.box.height).sorted()
        let lineHeight = heights[heights.count / 2]
        let rightEdge = sorted.map(\.box.maxX).max() ?? 1

        var result = first.text
        var previous = first
        for line in sorted.dropFirst() {
            let gap = previous.box.minY - line.box.maxY
            let isIndented = line.box.minX - previous.box.minX > lineHeight
            let previousEndsEarly = previous.box.maxX < rightEdge - lineHeight * 2
            if gap > lineHeight * 0.8 || isIndented || previousEndsEarly {
                result += "\n" + line.text
            } else if result.hasSuffix("-"), result.dropLast().last?.isLetter == true {
                result.removeLast()
                result += line.text
            } else if isCJK(result.last) || isCJK(line.text.first) {
                result += line.text
            } else {
                result += " " + line.text
            }
            previous = line
        }
        return result
    }

    private static func isCJK(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000 ... 0x30FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF, 0xFF00 ... 0xFFEF:
            return true
        default:
            return false
        }
    }
}
