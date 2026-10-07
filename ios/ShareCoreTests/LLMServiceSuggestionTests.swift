//
//  LLMServiceSuggestionTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("LLMService suggestions", .serialized)
struct LLMServiceSuggestionTests {
    @Test("Plain action prompts do not request follow-up suggestions")
    func plainActionPromptDoesNotRequestSuggestions() async throws {
        let session = URLSession(configuration: MockLLMURLProtocol.configuration)
        MockLLMURLProtocol.reset()
        MockLLMURLProtocol.responseBody = try Self.chatResponse(content: "Translated text")

        let service = LLMService(urlSession: session)
        let action = ActionConfig(
            name: "Rewrite",
            prompt: "Rewrite in {{targetLanguage}}: {{text}}",
            outputType: .markdown,
            category: .general
        )

        _ = await service.perform(
            text: "Hello",
            with: action,
            models: [Self.model],
            targetLanguageDescriptor: "Simplified Chinese",
            sourceLanguageDescriptor: "English"
        )

        let payload = try #require(MockLLMURLProtocol.capturedBodyString)
        #expect(!payload.contains("[SUGGESTIONS:"))
        #expect(!payload.localizedCaseInsensitiveContains("suggestion"))
    }

    @Test("Legacy suggestion markers are not converted into follow-up actions")
    func legacySuggestionMarkersAreNotConvertedIntoActions() async throws {
        let session = URLSession(configuration: MockLLMURLProtocol.configuration)
        MockLLMURLProtocol.reset()
        MockLLMURLProtocol.responseBody = try Self.chatResponse(
            content: "Translated text\n[SUGGESTIONS: Make formal | Shorten | Explain]"
        )

        let service = LLMService(urlSession: session)
        let action = ActionConfig(
            name: "Rewrite",
            prompt: "Rewrite: {{text}}",
            outputType: .markdown,
            category: .general
        )

        let results = await service.perform(
            text: "Hello",
            with: action,
            models: [Self.model],
            targetLanguageDescriptor: "Simplified Chinese",
            sourceLanguageDescriptor: "English"
        )

        let result = try #require(results.first)
        #expect(result.suggestedActions.isEmpty)
    }

    @Test("History annotation tool call executes before final response")
    func historyAnnotationToolCallExecutesBeforeFinalResponse() async throws {
        let targetID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let capture = AnnotationToolCapture()
        let session = URLSession(configuration: MockLLMURLProtocol.configuration)
        MockLLMURLProtocol.reset()
        MockLLMURLProtocol.responseBodies = try [
            Self.toolCallResponse(targetID: targetID, markdown: "**Key point**"),
            Self.chatResponse(content: "Annotation saved."),
        ]

        let service = LLMService(urlSession: session)
        let finalText = try await service.sendContinuation(
            messages: [.init(role: "user", content: "Annotate this.")],
            model: Self.model,
            annotationToolHandler: { request in
                capture.requests.append(request)
                return .init(success: true, message: "Saved")
            },
            partialHandler: { _ in }
        )

        #expect(finalText.content == "Annotation saved.")
        #expect(capture.requests.count == 1)
        #expect(capture.requests.first?.targetID == targetID.uuidString)
        #expect(capture.requests.first?.markdown == "**Key point**")

        let firstPayload = try #require(MockLLMURLProtocol.capturedBodyStrings.first?.data(using: .utf8))
        let firstJSON = try #require(JSONSerialization.jsonObject(with: firstPayload) as? [String: Any])
        #expect(firstJSON["tools"] != nil)

        let secondPayload = try #require(MockLLMURLProtocol.capturedBodyStrings.dropFirst().first?.data(using: .utf8))
        let secondJSON = try #require(JSONSerialization.jsonObject(with: secondPayload) as? [String: Any])
        let messages = try #require(secondJSON["messages"] as? [[String: Any]])
        #expect(messages.contains { $0["role"] as? String == "tool" })
    }

    @Test("History annotation continuation streams text when no tool is called")
    func historyAnnotationContinuationStreamsText() async throws {
        let partials = TextCapture()
        let session = URLSession(configuration: MockLLMURLProtocol.configuration)
        MockLLMURLProtocol.reset()
        MockLLMURLProtocol.responseBody = try Self.sseResponse([
            ["choices": [["delta": ["content": "Hello"]]]],
            ["choices": [["delta": ["content": " world"]]]],
        ])
        MockLLMURLProtocol.responseContentType = "text/event-stream"

        let service = LLMService(urlSession: session)
        let finalText = try await service.sendContinuation(
            messages: [.init(role: "user", content: "Reply.")],
            model: Self.model,
            annotationToolHandler: { _ in .init(success: true, message: "Saved") },
            partialHandler: { partials.values.append($0.content) }
        )

        #expect(finalText.content == "Hello world")
        #expect(partials.values == ["Hello", "Hello world"])
        let payload = try #require(MockLLMURLProtocol.capturedBodyString)
        #expect(payload.contains("\"stream\":true"))
        #expect(payload.contains("\"tools\""))
    }

    @Test("History annotation tool calls and final text both stream")
    func historyAnnotationToolCallStreamsFinalText() async throws {
        let targetID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let toolCapture = AnnotationToolCapture()
        let textCapture = TextCapture()
        let arguments = #"{"target_id":"\#(targetID.uuidString)","markdown":"**Streamed**"}"#
        let splitIndex = arguments.index(arguments.startIndex, offsetBy: arguments.count / 2)

        let session = URLSession(configuration: MockLLMURLProtocol.configuration)
        MockLLMURLProtocol.reset()
        MockLLMURLProtocol.responseBodies = try [
            Self.sseResponse([
                [
                    "choices": [[
                        "delta": [
                            "tool_calls": [[
                                "index": 0,
                                "id": "call_streamed_annotation",
                                "type": "function",
                                "function": [
                                    "name": "save_history_annotation",
                                    "arguments": String(arguments[..<splitIndex]),
                                ],
                            ]],
                        ],
                    ]],
                ],
                [
                    "choices": [[
                        "delta": [
                            "tool_calls": [[
                                "index": 0,
                                "function": [
                                    "arguments": String(arguments[splitIndex...]),
                                ],
                            ]],
                        ],
                    ]],
                ],
            ]),
            Self.sseResponse([
                ["choices": [["delta": ["content": "Annotation"]]]],
                ["choices": [["delta": ["content": " saved."]]]],
            ]),
        ]
        MockLLMURLProtocol.responseContentTypes = ["text/event-stream", "text/event-stream"]

        let service = LLMService(urlSession: session)
        let finalText = try await service.sendContinuation(
            messages: [.init(role: "user", content: "Annotate this.")],
            model: Self.model,
            annotationToolHandler: { request in
                toolCapture.requests.append(request)
                return .init(success: true, message: "Saved")
            },
            partialHandler: { textCapture.values.append($0.content) }
        )

        #expect(finalText.content == "Annotation saved.")
        #expect(textCapture.values == ["Annotation", "Annotation saved."])
        #expect(toolCapture.requests.first?.targetID == targetID.uuidString)
        #expect(toolCapture.requests.first?.markdown == "**Streamed**")
    }

    @Test("Continuation separates streamed reasoning content")
    func continuationSeparatesStreamedReasoningContent() async throws {
        let capture = ConversationResponseCapture()
        let session = URLSession(configuration: MockLLMURLProtocol.configuration)
        MockLLMURLProtocol.reset()
        MockLLMURLProtocol.responseBody = try Self.sseResponse([
            ["choices": [["delta": ["reasoning_content": "Check"]]]],
            ["choices": [["delta": ["reasoning_content": " details."]]]],
            ["choices": [["delta": ["content": "Final answer."]]]],
        ])
        MockLLMURLProtocol.responseContentType = "text/event-stream"

        let service = LLMService(urlSession: session)
        let response = try await service.sendContinuation(
            messages: [.init(role: "user", content: "Reply.")],
            model: Self.model,
            partialHandler: { capture.values.append($0) }
        )

        #expect(response == .init(reasoning: "Check details.", content: "Final answer."))
        #expect(capture.values.last == response)
    }

    @Test("Continuation separates think tags split across chunks")
    func continuationSeparatesSplitThinkTags() async throws {
        let capture = ConversationResponseCapture()
        let session = URLSession(configuration: MockLLMURLProtocol.configuration)
        MockLLMURLProtocol.reset()
        MockLLMURLProtocol.responseBody = try Self.sseResponse([
            ["choices": [["delta": ["content": "<thi"]]]],
            ["choices": [["delta": ["content": "nk>Check details."]]]],
            ["choices": [["delta": ["content": "</think>Final answer."]]]],
        ])
        MockLLMURLProtocol.responseContentType = "text/event-stream"

        let service = LLMService(urlSession: session)
        let response = try await service.sendContinuation(
            messages: [.init(role: "user", content: "Reply.")],
            model: Self.model,
            partialHandler: { capture.values.append($0) }
        )

        #expect(response == .init(reasoning: "Check details.", content: "Final answer."))
        #expect(capture.values.first == .init(reasoning: "Check details.", content: ""))
        #expect(capture.values.last == response)
    }

    @Test("Continuation separates non-streaming reasoning content")
    func continuationSeparatesNonStreamingReasoningContent() async throws {
        let capture = ConversationResponseCapture()
        let session = URLSession(configuration: MockLLMURLProtocol.configuration)
        MockLLMURLProtocol.reset()
        MockLLMURLProtocol.responseBody = try Self.chatResponse(
            content: "Final answer.",
            reasoning: "Check details."
        )

        let service = LLMService(urlSession: session)
        let response = try await service.sendContinuation(
            messages: [.init(role: "user", content: "Reply.")],
            model: Self.model,
            partialHandler: { capture.values.append($0) }
        )

        #expect(response == .init(reasoning: "Check details.", content: "Final answer."))
        #expect(capture.values.allSatisfy { $0.reasoning == "Check details." })
        #expect(capture.values.last == response)
    }

    @Test("Single continuation explicitly disables streaming")
    func singleContinuationDisablesStreaming() async throws {
        let session = URLSession(configuration: MockLLMURLProtocol.configuration)
        MockLLMURLProtocol.reset()
        MockLLMURLProtocol.responseBody = try Self.chatResponse(content: "Title")

        let service = LLMService(urlSession: session)
        let finalText = try await service.sendContinuationOnce(
            messages: [.init(role: "user", content: "Summarize.")],
            model: Self.model
        )

        #expect(finalText == "Title")
        let payload = try #require(MockLLMURLProtocol.capturedBodyString)
        #expect(payload.contains("\"stream\":false"))
    }

    @Test("Non-streaming fallback publishes the complete response once without a typewriter delay")
    func fallbackPublishesCompleteResponse() async throws {
        let capture = ConversationResponseCapture()
        let session = URLSession(configuration: MockLLMURLProtocol.configuration)
        MockLLMURLProtocol.reset()
        let text = String(repeating: "Translated paragraph. ", count: 200)
        MockLLMURLProtocol.responseBody = try Self.chatResponse(content: text)
        let service = LLMService(urlSession: session)
        let response = try await service.sendContinuation(
            messages: [.init(role: "user", content: "Reply.")],
            model: Self.model,
            partialHandler: { capture.values.append($0) }
        )
        #expect(capture.values == [response])
        #expect(response.content == text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let model = ModelConfig(id: "gpt-test", displayName: "GPT Test")

    private static func chatResponse(content: String, reasoning: String? = nil) throws -> Data {
        var message: [String: Any] = ["content": content]
        if let reasoning {
            message["reasoning_content"] = reasoning
        }
        return try JSONSerialization.data(withJSONObject: [
            "choices": [
                [
                    "message": message,
                ],
            ],
        ])
    }

    private static func toolCallResponse(targetID: UUID, markdown: String) throws -> Data {
        let argumentsData = try JSONSerialization.data(withJSONObject: [
            "target_id": targetID.uuidString,
            "markdown": markdown,
        ])
        let arguments = String(data: argumentsData, encoding: .utf8) ?? "{}"
        return try JSONSerialization.data(withJSONObject: [
            "choices": [
                [
                    "message": [
                        "content": NSNull(),
                        "tool_calls": [
                            [
                                "id": "call_annotation",
                                "type": "function",
                                "function": [
                                    "name": "save_history_annotation",
                                    "arguments": arguments,
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])
    }

    private static func sseResponse(_ events: [[String: Any]]) throws -> Data {
        var response = ""
        for event in events {
            let data = try JSONSerialization.data(withJSONObject: event)
            response += "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
        response += "data: [DONE]\n\n"
        return Data(response.utf8)
    }
}

private final class AnnotationToolCapture: @unchecked Sendable {
    var requests: [HistoryAnnotationToolRequest] = []
}

private final class TextCapture: @unchecked Sendable {
    var values: [String] = []
}

private final class ConversationResponseCapture: @unchecked Sendable {
    var values: [ConversationResponse] = []
}

private class MockLLMURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var responseBodies: [Data] = []
    nonisolated(unsafe) static var responseContentType = "application/json"
    nonisolated(unsafe) static var responseContentTypes: [String] = []
    nonisolated(unsafe) static var capturedBodyString: String?
    nonisolated(unsafe) static var capturedBodyStrings: [String] = []

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLLMURLProtocol.self]
        return configuration
    }

    static func reset() {
        responseBody = Data()
        responseBodies = []
        responseContentType = "application/json"
        responseContentTypes = []
        capturedBodyString = nil
        capturedBodyStrings = []
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let body = requestBodyData() {
            let bodyString = String(data: body, encoding: .utf8)
            Self.capturedBodyString = bodyString
            if let bodyString {
                Self.capturedBodyStrings.append(bodyString)
            }
        }

        let contentType = Self.responseContentTypes.isEmpty
            ? Self.responseContentType
            : Self.responseContentTypes.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = Self.responseBodies.isEmpty ? Self.responseBody : Self.responseBodies.removeFirst()
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBodyData() -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
            } else {
                break
            }
        }

        return data.isEmpty ? nil : data
    }
}
