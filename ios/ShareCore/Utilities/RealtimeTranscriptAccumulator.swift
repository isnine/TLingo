import Foundation

public enum RealtimeRecognitionState: Equatable, Sendable {
    case partial
    case final
}

public struct RealtimeRecognitionTokenTiming: Equatable, Sendable {
    public let token: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Double

    public init(
        token: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double
    ) {
        self.token = token
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

public enum RealtimeRecognitionBoundaryReason: String, Equatable, Sendable {
    case modelEOU
    case punctuation
    case stableWindow
    case lengthFallback
    case terminal
}

public struct RealtimeRecognitionSegment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let startOffset: TimeInterval
    public let endOffset: TimeInterval
    public let speakerID: String?
    public let boundaryReason: RealtimeRecognitionBoundaryReason

    public init(
        id: UUID = UUID(),
        text: String,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        speakerID: String? = nil,
        boundaryReason: RealtimeRecognitionBoundaryReason
    ) {
        self.id = id
        self.text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.speakerID = speakerID
        self.boundaryReason = boundaryReason
    }
}

public struct RealtimeRecognitionSnapshot: Equatable, Sendable {
    public let stableText: String
    public let volatileText: String
    public let stableSegments: [RealtimeRecognitionSegment]
    public let pendingSegment: RealtimeRecognitionSegment?
    public let tokenTimings: [RealtimeRecognitionTokenTiming]
    public let audioOffset: TimeInterval?
    public let isTerminal: Bool

    public var visibleText: String {
        Self.joined(stableText, volatileText)
    }

    public init(
        stableText: String,
        volatileText: String = "",
        tokenTimings: [RealtimeRecognitionTokenTiming] = [],
        audioOffset: TimeInterval? = nil,
        isTerminal: Bool = false
    ) {
        self.stableText = Self.normalized(stableText)
        self.volatileText = Self.normalized(volatileText)
        stableSegments = []
        pendingSegment = nil
        self.tokenTimings = tokenTimings
        self.audioOffset = audioOffset
        self.isTerminal = isTerminal
    }

    public init(
        stableSegments: [RealtimeRecognitionSegment],
        pendingSegment: RealtimeRecognitionSegment? = nil,
        tokenTimings: [RealtimeRecognitionTokenTiming] = [],
        audioOffset: TimeInterval? = nil,
        isTerminal: Bool = false
    ) {
        self.stableSegments = stableSegments.filter { !$0.text.isEmpty }
        self.pendingSegment = pendingSegment?.text.isEmpty == false ? pendingSegment : nil
        stableText = self.stableSegments.map(\.text).joined(separator: "\n\n")
        volatileText = self.pendingSegment?.text ?? ""
        self.tokenTimings = tokenTimings
        self.audioOffset = audioOffset
        self.isTerminal = isTerminal
    }

    private static func joined(_ stable: String, _ volatile: String) -> String {
        [stable, volatile]
            .map(normalized)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalized(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

public struct RealtimeRecognitionResult: Equatable, Sendable {
    public let text: String
    public let confidence: Double
    public let state: RealtimeRecognitionState
    public let audioOffset: TimeInterval?
    public let snapshot: RealtimeRecognitionSnapshot?

    public init(
        text: String,
        confidence: Double,
        state: RealtimeRecognitionState,
        audioOffset: TimeInterval? = nil
    ) {
        self.text = text
        self.confidence = confidence
        self.state = state
        self.audioOffset = audioOffset
        snapshot = nil
    }

    public init(
        snapshot: RealtimeRecognitionSnapshot,
        confidence: Double = 0.5
    ) {
        text = snapshot.visibleText
        self.confidence = confidence
        state = snapshot.isTerminal ? .final : .partial
        audioOffset = snapshot.audioOffset
        self.snapshot = snapshot
    }
}

public struct RealtimeTranscriptAccumulator {
    public private(set) var committedText: String
    public private(set) var partialText: String
    private var isSnapshotBacked: Bool

    public var visibleText: String {
        joined(committedText, partialText)
    }

    public var translationSourceText: String {
        committedText
    }

    public var pendingSentenceText: String {
        partialText
    }

    public init(committedText: String = "", partialText: String = "") {
        self.committedText = committedText
        self.partialText = partialText
        isSnapshotBacked = false
    }

    @discardableResult
    public mutating func append(_ text: String, afterLongSilence: Bool) -> String {
        isSnapshotBacked = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if afterLongSilence, let suffix = longSilenceOverlappingSuffix(in: trimmed) {
            committedText = joined(committedText, partialText)
            partialText = suffix
            return visibleText
        }
        if afterLongSilence,
           !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           isRecognitionRevision(of: partialText, replacement: trimmed)
        {
            partialText = trimmed
            return visibleText
        }
        if !afterLongSilence, partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           shouldReplaceLastCommittedSegment(with: trimmed)
        {
            removeLastCommittedSegment()
            partialText = trimmed
            return visibleText
        }
        if !afterLongSilence, !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let suffix = partialSuffix(afterCommittedPrefixIn: trimmed)
        {
            partialText = suffix
            return visibleText
        }

        if afterLongSilence || startsNewPartial(text) {
            committedText = joined(committedText, partialText)
        }

        partialText = text
        return visibleText
    }

    @discardableResult
    public mutating func append(_ result: RealtimeRecognitionResult, afterLongSilence: Bool) -> String {
        if let snapshot = result.snapshot {
            return replace(with: snapshot)
        }
        isSnapshotBacked = false
        switch result.state {
        case .partial:
            return append(result.text, afterLongSilence: afterLongSilence)
        case .final:
            return appendFinal(result.text)
        }
    }

    public mutating func reset() {
        committedText = ""
        partialText = ""
        isSnapshotBacked = false
    }

    @discardableResult
    public mutating func replace(with snapshot: RealtimeRecognitionSnapshot) -> String {
        committedText = snapshot.stableText
        partialText = snapshot.volatileText
        isSnapshotBacked = true
        return visibleText
    }

    @discardableResult
    public mutating func commitPartial() -> String {
        committedText = joined(committedText, partialText)
        partialText = ""
        return visibleText
    }

    @discardableResult
    private mutating func appendFinal(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return visibleText }

        if Self.whitespaceInsensitiveSuffix(after: visibleText, in: trimmed) != nil {
            committedText = trimmed
            partialText = ""
            return visibleText
        }
        if let suffix = Self.whitespaceInsensitiveSuffix(after: trimmed, in: visibleText) {
            committedText = trimmed
            partialText = suffix
            return visibleText
        }
        if shouldReplaceLastCommittedSegment(with: trimmed) {
            replaceLastCommittedSegment(with: trimmed)
            partialText = remainingPartialText(afterFinalText: trimmed)
            return visibleText
        }
        if let suffix = Self.suffix(after: trimmed, in: partialText) {
            committedText = joined(committedText, trimmed)
            partialText = suffix
            return visibleText
        }

        _ = append(trimmed, afterLongSilence: false)
        return commitPartial()
    }

    private func joined(_ committed: String, _ partial: String) -> String {
        switch (committed.isEmpty, partial.isEmpty) {
        case (true, true):
            return ""
        case (true, false):
            return partial
        case (false, true):
            return committed
        case (false, false):
            return isSnapshotBacked ? "\(committed) \(partial)" : "\(committed)\n\n\(partial)"
        }
    }

    private func startsNewPartial(_ text: String) -> Bool {
        guard !partialText.isEmpty else { return false }
        if isRecognitionRevision(of: partialText, replacement: text) {
            return false
        }
        return !text.hasPrefix(partialText) && !partialText.hasPrefix(text)
    }

    private func partialSuffix(afterCommittedPrefixIn snapshot: String) -> String? {
        let committed = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committed.isEmpty else { return nil }
        return Self.whitespaceInsensitiveSuffix(after: committed, in: snapshot)
    }

    private func longSilenceOverlappingSuffix(in snapshot: String) -> String? {
        let visible = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return nil }

        let segments = visible.components(separatedBy: "\n\n")
        for index in segments.indices {
            let candidate = segments[index...]
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { continue }
            if let suffix = Self.whitespaceInsensitiveSuffix(after: candidate, in: snapshot) {
                return suffix
            }
        }
        return nil
    }

    private func shouldReplaceLastCommittedSegment(with replacement: String) -> Bool {
        let segments = committedText.components(separatedBy: "\n\n")
        guard let index = segments.lastIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return false
        }

        let previous = segments[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return shouldReplaceCommittedSegment(previous, with: replacement)
    }

    private mutating func replaceLastCommittedSegment(with replacement: String) {
        var segments = committedText.components(separatedBy: "\n\n")
        guard let index = segments.lastIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return
        }
        segments[index] = replacement
        committedText = segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private mutating func removeLastCommittedSegment() {
        var segments = committedText.components(separatedBy: "\n\n")
        guard let index = segments.lastIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return
        }
        segments.remove(at: index)
        committedText = segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func remainingPartialText(afterFinalText finalText: String) -> String {
        let partial = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partial.isEmpty else { return "" }

        if let suffix = Self.suffix(after: finalText, in: partial) {
            return suffix
        }
        if isRecognitionRevision(of: partial, replacement: finalText) {
            return ""
        }
        return partial
    }

    private func shouldReplaceCommittedSegment(_ previous: String, with replacement: String) -> Bool {
        if replacement.hasPrefix(previous) {
            return true
        }

        if isRecognitionRevision(of: previous, replacement: replacement) {
            return true
        }

        let previousNormalized = Self.normalizedRecognitionText(previous)
        let replacementNormalized = Self.normalizedRecognitionText(replacement)
        guard !previousNormalized.isEmpty, !replacementNormalized.isEmpty else { return false }
        return replacementNormalized == previousNormalized || replacementNormalized.hasPrefix("\(previousNormalized) ")
    }

    private func isRecognitionRevision(of previous: String, replacement: String) -> Bool {
        let previousNormalized = Self.normalizedRecognitionText(previous)
        let replacementNormalized = Self.normalizedRecognitionText(replacement)
        guard !previousNormalized.isEmpty, !replacementNormalized.isEmpty else { return false }
        if previousNormalized == replacementNormalized {
            return true
        }

        let shorterLength = min(previousNormalized.count, replacementNormalized.count)
        let previousTokens = Set(previousNormalized.split(separator: " "))
        let replacementTokens = Set(replacementNormalized.split(separator: " "))
        let commonPrefixLength = zip(previousNormalized, replacementNormalized).prefix { $0 == $1 }.count
        if shorterLength >= 12 {
            if Double(commonPrefixLength) / Double(shorterLength) >= 0.45 {
                return true
            }
        }

        let isSimilarSingleTokenRevision = shorterLength >= 4 &&
            previousTokens.count == 1 &&
            replacementTokens.count == 1 &&
            Self.hasHighSingleTokenCharacterSimilarity(
                previousNormalized,
                replacementNormalized,
                shorterLength: shorterLength
            )
        if isSimilarSingleTokenRevision {
            return true
        }

        guard previousTokens.count >= 4, replacementTokens.count >= 4 else { return false }

        let sharedTokenCount = previousTokens.intersection(replacementTokens).count
        let shorterTokenCount = min(previousTokens.count, replacementTokens.count)
        return Double(sharedTokenCount) / Double(shorterTokenCount) >= 0.6
    }

    private static func hasHighSingleTokenCharacterSimilarity(
        _ previous: String,
        _ replacement: String,
        shorterLength: Int
    ) -> Bool {
        let sharedCharacterCount = longestCommonSubsequenceLength(previous, replacement)
        return Double(sharedCharacterCount) / Double(shorterLength) >= 0.75
    }

    private static func longestCommonSubsequenceLength(_ previous: String, _ replacement: String) -> Int {
        let previousCharacters = Array(previous)
        let replacementCharacters = Array(replacement)
        guard !previousCharacters.isEmpty, !replacementCharacters.isEmpty else { return 0 }

        var previousRow = Array(repeating: 0, count: replacementCharacters.count + 1)
        var currentRow = previousRow
        for previousIndex in previousCharacters.indices {
            for replacementIndex in replacementCharacters.indices {
                if previousCharacters[previousIndex] == replacementCharacters[replacementIndex] {
                    currentRow[replacementIndex + 1] = previousRow[replacementIndex] + 1
                } else {
                    currentRow[replacementIndex + 1] = max(
                        currentRow[replacementIndex],
                        previousRow[replacementIndex + 1]
                    )
                }
            }
            swap(&previousRow, &currentRow)
        }
        return previousRow[replacementCharacters.count]
    }

    private static func normalizedRecognitionText(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func suffix(after prefix: String, in text: String) -> String? {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty, trimmedText.hasPrefix(trimmedPrefix) else { return nil }

        let suffixStart = trimmedText.index(trimmedText.startIndex, offsetBy: trimmedPrefix.count)
        return String(trimmedText[suffixStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func whitespaceInsensitiveSuffix(after prefix: String, in text: String) -> String? {
        let prefixCharacters = prefix.filter { !$0.isWhitespace }
        guard !prefixCharacters.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }

        var textIndex = text.startIndex
        for prefixCharacter in prefixCharacters {
            while textIndex < text.endIndex, text[textIndex].isWhitespace {
                textIndex = text.index(after: textIndex)
            }
            guard textIndex < text.endIndex, text[textIndex] == prefixCharacter else { return nil }
            textIndex = text.index(after: textIndex)
        }

        return String(text[textIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
