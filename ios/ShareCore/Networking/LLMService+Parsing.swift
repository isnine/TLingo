//
//  LLMService+Parsing.swift
//  ShareCore
//

import Foundation

/// Incremental parser for streaming structured output (e.g., grammar check).
/// Extracts field values as they stream in, hiding the JSON structure from the user.
final class StreamingStructuredOutputParser {
    private static let backslash: UTF16.CodeUnit = 0x5C
    private static let quote: UTF16.CodeUnit = 0x22

    private var prefixBuffer = ""
    /// Undecoded UTF-16 units of the primary field value, e.g. an escape split across deltas.
    private var pendingUnits: [UTF16.CodeUnit] = []
    private var displayText = ""
    private var hasValueStart = false
    private var isComplete = false
    private let fieldRegex: NSRegularExpression?

    init(config: ActionConfig.StructuredOutputConfig) {
        let escapedField = NSRegularExpression.escapedPattern(for: config.primaryField)
        let fieldPattern = "\"\(escapedField)\"\\s*:\\s*\""
        fieldRegex = try? NSRegularExpression(pattern: fieldPattern, options: [])
    }

    /// Append new delta text and return the display text for UI.
    /// Each delta is decoded once, so a long response stays linear.
    func append(_ delta: String) -> String {
        guard !isComplete else { return displayText }
        if hasValueStart {
            pendingUnits.append(contentsOf: delta.utf16)
        } else {
            // Look for pattern like "revised_text": "..."
            prefixBuffer.append(delta)
            guard let fieldRegex else { return "" }
            let range = NSRange(location: 0, length: (prefixBuffer as NSString).length)
            guard let match = fieldRegex.firstMatch(in: prefixBuffer, options: [], range: range) else {
                return ""
            }
            hasValueStart = true
            pendingUnits = Array(prefixBuffer.utf16.dropFirst(match.range.upperBound))
            prefixBuffer = ""
        }
        decodePendingUnits()
        return displayText
    }

    private func decodePendingUnits() {
        var decoded: [UTF16.CodeUnit] = []
        var index = 0
        scan: while index < pendingUnits.count {
            let unit = pendingUnits[index]
            if unit == Self.quote {
                // End of string value
                isComplete = true
                index = pendingUnits.count
                break
            }
            guard unit == Self.backslash else {
                decoded.append(unit)
                index += 1
                continue
            }
            guard index + 1 < pendingUnits.count else { break }
            switch pendingUnits[index + 1] {
            case 0x6E: decoded.append(0x0A) // \n
            case 0x74: decoded.append(0x09) // \t
            case 0x72: decoded.append(0x0D) // \r
            case 0x62: decoded.append(0x08) // \b
            case 0x66: decoded.append(0x0C) // \f
            case 0x75: // \uXXXX
                guard index + 6 <= pendingUnits.count else { break scan }
                let hex = String(decoding: pendingUnits[(index + 2) ..< (index + 6)], as: UTF16.self)
                if let value = UInt16(hex, radix: 16) {
                    decoded.append(value)
                }
                index += 6
                continue
            default: // \" \\ \/
                decoded.append(pendingUnits[index + 1])
            }
            index += 2
        }
        pendingUnits.removeFirst(index)
        // A lead surrogate waits for its trail, which may arrive as a later escape.
        if !isComplete, let last = decoded.last, UTF16.isLeadSurrogate(last) {
            decoded.removeLast()
            pendingUnits.insert(contentsOf: [last], at: 0)
        }
        displayText.append(String(decoding: decoded, as: UTF16.self))
    }
}

/// Incremental JSON parser for streaming sentence pairs.
/// Extracts completed sentence pair objects as they become available.
final class StreamingSentencePairParser {
    private var buffer = ""
    private var emittedPairs: [SentencePair] = []
    private var scanOffset = 0
    private let pairRegex: NSRegularExpression?

    init() {
        let pattern =
            #"\{\s*"(?:original|translation)"\s*:\s*"(?:[^"\\]|\\.)*"\s*,\s*"(?:original|translation)"\s*:\s*"(?:[^"\\]|\\.)*"\s*\}"#
        pairRegex = try? NSRegularExpression(pattern: pattern, options: [])
    }

    /// Append new delta text and return all completed pairs found so far.
    func append(_ delta: String) -> [SentencePair] {
        buffer.append(delta)

        // Try to extract completed sentence pair objects
        let newPairs = extractCompletedPairs()
        if !newPairs.isEmpty {
            emittedPairs.append(contentsOf: newPairs)
        }

        return emittedPairs
    }

    private func extractCompletedPairs() -> [SentencePair] {
        var pairs: [SentencePair] = []

        guard let regex = pairRegex else {
            return pairs
        }

        let nsString = buffer as NSString
        let searchRange = NSRange(location: scanOffset, length: nsString.length - scanOffset)
        let matches = regex.matches(in: buffer, options: [], range: searchRange)

        for match in matches {
            let matchString = nsString.substring(with: match.range)
            if let pair = parseSinglePair(matchString) {
                pairs.append(pair)
            }
            // Advance scan offset past this match
            scanOffset = match.range.upperBound
        }

        return pairs
    }

    private func parseSinglePair(_ jsonString: String) -> SentencePair? {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let original = dict["original"],
              let translation = dict["translation"]
        else {
            return nil
        }

        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranslation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOriginal.isEmpty, !trimmedTranslation.isEmpty else {
            return nil
        }

        return SentencePair(
            original: trimmedOriginal,
            translation: trimmedTranslation
        )
    }
}

extension LLMService {
    struct ChatCompletionsResponse: Decodable {
        struct Choice: Decodable {
            let message: Message
        }

        struct Message: Decodable {
            let content: MessageContent?
            let reasoningContent: String?
            let toolCalls: [ToolCall]?
        }

        struct ToolCall: Decodable {
            struct FunctionCall: Decodable {
                let name: String
                let arguments: String
            }

            let id: String
            let type: String
            let function: FunctionCall
        }

        enum MessageContent: Decodable {
            case text(String)
            case parts([MessagePart])

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    self = .text(text)
                } else if let parts = try? container.decode([MessagePart].self) {
                    self = .parts(parts)
                } else {
                    self = .text("")
                }
            }
        }

        struct MessagePart: Decodable {
            let type: String?
            let text: String?
            let data: String?
            let content: String?
            let json: JSONValue?
            let jsonSchema: JSONSchemaPayload?
        }

        struct JSONSchemaPayload: Decodable {
            let name: String?
            let schema: JSONValue?
            let output: JSONValue?
            let result: JSONValue?
            let json: JSONValue?
        }

        let choices: [Choice]?
    }

    struct ChatCompletionsStreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct ToolCallDelta: Decodable {
                    struct FunctionDelta: Decodable {
                        let name: String?
                        let arguments: String?
                    }

                    let index: Int
                    let id: String?
                    let type: String?
                    let function: FunctionDelta?
                }

                let content: String?
                let reasoningContent: String?
                let toolCalls: [ToolCallDelta]?
            }

            let delta: Delta?
        }

        /// Upstream providers report mid-stream failures as an `error` frame
        /// without `choices`, either as an object or a bare string.
        struct StreamError: Decodable {
            let message: String?

            init(from decoder: Decoder) throws {
                if let text = try? decoder.singleValueContainer().decode(String.self) {
                    message = text
                } else {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    message = try container.decodeIfPresent(String.self, forKey: .message)
                }
            }

            private enum CodingKeys: String, CodingKey {
                case message
            }
        }

        let choices: [Choice]?
        let error: StreamError?

        var combinedText: String {
            (choices ?? []).compactMap { $0.delta?.content }.joined()
        }

        var combinedReasoning: String {
            (choices ?? []).compactMap { $0.delta?.reasoningContent }.joined()
        }

        var toolCallDeltas: [Choice.Delta.ToolCallDelta] {
            (choices ?? []).flatMap { $0.delta?.toolCalls ?? [] }
        }

        static func decode(_ data: Data, using decoder: JSONDecoder) throws -> ChatCompletionsStreamChunk {
            let chunk = try decoder.decode(ChatCompletionsStreamChunk.self, from: data)
            if let error = chunk.error {
                throw LLMServiceError.streamError(message: error.message ?? "")
            }
            return chunk
        }
    }

    struct StreamingContinuationResult {
        let response: ConversationResponse
        let toolCalls: [ChatCompletionsResponse.ToolCall]
    }

    struct ConversationResponseAccumulator {
        private var reasoning = ""
        private var content = ""

        mutating func append(reasoning reasoningDelta: String, content contentDelta: String) -> ConversationResponse {
            reasoning.append(reasoningDelta)
            content.append(contentDelta)
            return ConversationResponse.split(reasoning: reasoning, content: content, isFinal: false)
        }

        func finalResponse() -> ConversationResponse {
            ConversationResponse.split(reasoning: reasoning, content: content, isFinal: true)
        }
    }

    struct StreamingToolCallAccumulator {
        private struct PartialToolCall {
            var id = ""
            var type = "function"
            var name = ""
            var arguments = ""
        }

        private var partials: [Int: PartialToolCall] = [:]

        mutating func append(_ deltas: [ChatCompletionsStreamChunk.Choice.Delta.ToolCallDelta]) {
            for delta in deltas {
                var partial = partials[delta.index] ?? PartialToolCall()
                if let id = delta.id {
                    partial.id = id
                }
                if let type = delta.type {
                    partial.type = type
                }
                if let name = delta.function?.name {
                    partial.name += name
                }
                if let arguments = delta.function?.arguments {
                    partial.arguments += arguments
                }
                partials[delta.index] = partial
            }
        }

        var toolCalls: [ChatCompletionsResponse.ToolCall] {
            partials.keys.sorted().compactMap { index in
                guard let partial = partials[index], !partial.id.isEmpty, !partial.name.isEmpty else {
                    return nil
                }
                return ChatCompletionsResponse.ToolCall(
                    id: partial.id,
                    type: partial.type,
                    function: .init(name: partial.name, arguments: partial.arguments)
                )
            }
        }
    }

    enum JSONValue: Codable {
        case string(String)
        case number(Double)
        case object([String: JSONValue])
        case array([JSONValue])
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else if let int = try? container.decode(Int.self) {
                self = .number(Double(int))
            } else if let double = try? container.decode(Double.self) {
                self = .number(double)
            } else if let object = try? container.decode([String: JSONValue].self) {
                self = .object(object)
            } else if let array = try? container.decode([JSONValue].self) {
                self = .array(array)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported JSON value"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .string(value):
                try container.encode(value)
            case let .number(value):
                try container.encode(value)
            case let .object(value):
                try container.encode(value)
            case let .array(value):
                try container.encode(value)
            case let .bool(value):
                try container.encode(value)
            case .null:
                try container.encodeNil()
            }
        }
    }
}

extension LLMService.JSONValue {
    var objectValue: [String: LLMService.JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var renderedString: String? {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            if value.isFinite {
                let integer = Int64(value)
                if Double(integer) == value {
                    return String(integer)
                }
            }
            return String(value)
        case let .bool(value):
            return value ? "true" : "false"
        case let .object(value):
            guard let data = try? JSONEncoder.llmEncoder.encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        case let .array(value):
            guard let data = try? JSONEncoder.llmEncoder.encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        case .null:
            return nil
        }
    }

    static func dictionary(from string: String) -> [String: LLMService.JSONValue]? {
        guard let data = string.data(using: .utf8),
              let value = try? JSONDecoder.llmDecoder.decode(LLMService.JSONValue.self, from: data),
              case let .object(object) = value
        else {
            return nil
        }
        return object
    }
}

extension LLMService.ChatCompletionsResponse.Message {
    typealias JSONValue = LLMService.JSONValue

    func structuredDictionary() -> [String: JSONValue]? {
        guard let content else { return nil }
        switch content {
        case let .text(text):
            return JSONValue.dictionary(from: text)
        case let .parts(parts):
            for part in parts {
                if let json = part.json?.objectValue {
                    return json
                }
                if let schema = part.jsonSchema {
                    if let output = schema.output?.objectValue {
                        return output
                    }
                    if let result = schema.result?.objectValue {
                        return result
                    }
                    if let json = schema.json?.objectValue {
                        return json
                    }
                }
                if let text = part.text,
                   let dictionary = JSONValue.dictionary(from: text)
                {
                    return dictionary
                }
                if let content = part.content,
                   let dictionary = JSONValue.dictionary(from: content)
                {
                    return dictionary
                }
            }
            return nil
        }
    }

    func plainText() -> String {
        guard let content else { return "" }
        switch content {
        case let .text(text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let .parts(parts):
            var fragments: [String] = []
            for part in parts {
                if let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty
                {
                    fragments.append(text)
                }
                if let content = part.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !content.isEmpty
                {
                    fragments.append(content)
                }
                if let data = part.data?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !data.isEmpty
                {
                    fragments.append(data)
                }
                if let json = part.json?.renderedString?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !json.isEmpty
                {
                    fragments.append(json)
                }
                if let output = part.jsonSchema?.output?.renderedString?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty
                {
                    fragments.append(output)
                }
                if let result = part.jsonSchema?.result?.renderedString?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !result.isEmpty
                {
                    fragments.append(result)
                }
            }
            return fragments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func conversationResponse() -> ConversationResponse {
        ConversationResponse.split(
            reasoning: reasoningContent ?? "",
            content: plainText(),
            isFinal: true
        )
    }
}

extension ConversationResponse {
    static func split(reasoning: String, content: String, isFinal: Bool) -> ConversationResponse {
        let firstContentIndex = content.firstIndex { !$0.isWhitespace } ?? content.endIndex
        let candidate = content[firstContentIndex...]
        let openingTag = "<think>"

        // `candidate.count` walks the whole response on every delta; the ASCII tag makes
        // the O(1) UTF-8 length equivalent once `candidate` is known to prefix it.
        if !isFinal, openingTag.hasPrefix(candidate), candidate.utf8.count < openingTag.utf8.count {
            return .init(reasoning: reasoning, content: "")
        }

        guard candidate.hasPrefix(openingTag) else {
            return .init(
                reasoning: isFinal ? reasoning.trimmingCharacters(in: .whitespacesAndNewlines) : reasoning,
                content: isFinal ? content.trimmingCharacters(in: .whitespacesAndNewlines) : content
            )
        }

        let reasoningStart = candidate.index(candidate.startIndex, offsetBy: openingTag.count)
        let remainder = candidate[reasoningStart...]
        guard let closingRange = remainder.range(of: "</think>") else {
            let embeddedReasoning = String(remainder)
            return .init(
                reasoning: [reasoning, embeddedReasoning].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                content: ""
            )
        }

        let embeddedReasoning = String(remainder[..<closingRange.lowerBound])
        let answer = String(remainder[closingRange.upperBound...])
        let combinedReasoning = [reasoning, embeddedReasoning]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return .init(
            reasoning: isFinal ? combinedReasoning.trimmingCharacters(in: .whitespacesAndNewlines) : combinedReasoning,
            content: isFinal ? answer.trimmingCharacters(in: .whitespacesAndNewlines) : answer
        )
    }
}

extension LLMService {
    static let saveHistoryAnnotationToolName = "save_history_annotation"

    static let saveHistoryAnnotationTool: [String: Any] = [
        "type": "function",
        "function": [
            "name": saveHistoryAnnotationToolName,
            "description": "Save a Markdown annotation for the current non-realtime TLingo history record or one listed realtime cell.",
            "strict": true,
            "parameters": [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "target_id": [
                        "type": "string",
                        "description": "Cell ID for realtime audio records, or History Record ID for non-realtime records.",
                    ],
                    "markdown": [
                        "type": "string",
                        "description": "CommonMark Markdown rendered visually in history. Prefer bold, bullets, numbered steps, "
                            + "inline code, block quotes, and useful links. Use short tables or task lists only when helpful. "
                            + "Avoid images, large code blocks, and repeating the original/source text.",
                    ],
                ],
                "required": ["target_id", "markdown"],
            ],
        ],
    ]

    struct SaveHistoryAnnotationArguments: Decodable {
        let targetId: String
        let markdown: String
    }

    struct ParsedResponse {
        let message: String
        let diffSource: String?
        let supplementalTexts: [String]
        let sentencePairs: [SentencePair]
    }

    static func historyAnnotationToolOutput(_ result: HistoryAnnotationToolResult) -> String {
        let object: [String: Any] = [
            "success": result.success,
            "message": result.message,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let output = String(data: data, encoding: .utf8)
        else {
            return result.message
        }
        return output
    }

    static func assistantToolCallMessageDictionary(
        toolCalls: [ChatCompletionsResponse.ToolCall]
    ) -> [String: Any] {
        [
            "role": "assistant",
            "content": NSNull(),
            "tool_calls": toolCalls.map { toolCall in
                [
                    "id": toolCall.id,
                    "type": toolCall.type,
                    "function": [
                        "name": toolCall.function.name,
                        "arguments": toolCall.function.arguments,
                    ],
                ]
            },
        ]
    }

    func hasPremiumEntitlement(refresh: Bool, cachedIsPremium: Bool? = nil) async -> Bool {
        if refresh {
            return await Entitlement.shared.refreshAndGetIsPro()
        }
        if let cachedIsPremium {
            return cachedIsPremium
        }
        return await MainActor.run { Entitlement.shared.isPro }
    }

    func applyUsageSubjectHeaders(to request: inout URLRequest) async {
        guard let subject = await UsageSubjectProvider.current() else { return }
        request.setValue(subject.type, forHTTPHeaderField: "X-Usage-Subject-Type")
        request.setValue(subject.id, forHTTPHeaderField: "X-Usage-Subject-ID")
        request.setValue(subject.label, forHTTPHeaderField: "X-Usage-Subject-Label")
    }

    func decodeConversationResponse(_ data: Data) throws -> ConversationResponse {
        let response = try JSONDecoder.llmDecoder.decode(ChatCompletionsResponse.self, from: data)
        guard let message = response.choices?.first?.message else {
            throw LLMServiceError.emptyContent
        }
        let conversationResponse = message.conversationResponse()
        guard !conversationResponse.content.isEmpty else {
            throw LLMServiceError.emptyContent
        }
        return conversationResponse
    }

    func parseResponsePayload(
        data: Data,
        structuredOutput: ActionConfig.StructuredOutputConfig?
    ) throws -> ParsedResponse {
        let response = try JSONDecoder.llmDecoder.decode(ChatCompletionsResponse.self, from: data)
        guard let message = response.choices?.first?.message else {
            throw LLMServiceError.emptyContent
        }

        if let structuredOutput,
           let dictionary = message.structuredDictionary()
        {
            let sentencePairsField = ActionConfig.StructuredOutputConfig.sentencePairsFieldName
            if structuredOutput.primaryField == sentencePairsField,
               let pairsValue = dictionary[sentencePairsField],
               case let .array(pairsArray) = pairsValue
            {
                let pairs = pairsArray.compactMap { item -> SentencePair? in
                    guard case let .object(obj) = item,
                          let originalValue = obj["original"],
                          let translationValue = obj["translation"],
                          let original = originalValue.renderedString?.trimmingCharacters(in: .whitespacesAndNewlines),
                          let translation = translationValue.renderedString?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !original.isEmpty, !translation.isEmpty
                    else {
                        return nil
                    }
                    return SentencePair(original: original, translation: translation)
                }

                if !pairs.isEmpty {
                    // Build combined text for fallback/copy
                    let combinedText = pairs.map { "\($0.original)\n\($0.translation)" }.joined(separator: "\n\n")
                    return ParsedResponse(
                        message: combinedText,
                        diffSource: nil,
                        supplementalTexts: [],
                        sentencePairs: pairs
                    )
                }
            }

            // Standard structured output handling
            if let primaryValue = dictionary[structuredOutput.primaryField]?.renderedString?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !primaryValue.isEmpty
            {
                var supplemental: [String] = []
                for field in structuredOutput.additionalFields {
                    guard let value = dictionary[field]?.renderedString?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !value.isEmpty
                    else {
                        continue
                    }
                    supplemental.append(value)
                }
                var sections = [primaryValue]
                sections.append(contentsOf: supplemental)
                let combined = sections.joined(separator: "\n\n")
                if !combined.isEmpty {
                    return ParsedResponse(
                        message: combined,
                        diffSource: primaryValue,
                        supplementalTexts: supplemental,
                        sentencePairs: []
                    )
                }
            }
        }

        let fallback = message.plainText()
        guard !fallback.isEmpty else {
            throw LLMServiceError.emptyContent
        }
        return ParsedResponse(
            message: fallback,
            diffSource: nil,
            supplementalTexts: [],
            sentencePairs: []
        )
    }
}

extension JSONDecoder {
    static let llmDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

extension JSONEncoder {
    static let llmEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
