//
//  LLMService.swift
//  ShareCore
//
//  Created by Codex on 2025/10/19.
//
import Foundation
import os

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "LLMService")

/// Represents a streaming update that can be either plain text or sentence pairs.
public enum StreamingUpdate: Sendable {
    case text(String)
    case sentencePairs([SentencePair])
}

public struct ConversationResponse: Sendable, Equatable {
    public let reasoning: String
    public let content: String

    public init(reasoning: String = "", content: String) {
        self.reasoning = reasoning
        self.content = content
    }
}

public struct HistoryAnnotationToolRequest: Sendable {
    public let targetID: String
    public let markdown: String

    public init(targetID: String, markdown: String) {
        self.targetID = targetID
        self.markdown = markdown
    }
}

public struct HistoryAnnotationToolResult: Sendable {
    public let success: Bool
    public let message: String

    public init(success: Bool, message: String) {
        self.success = success
        self.message = message
    }
}

public final class LLMService {
    public static let shared = LLMService()

    private let urlSession: URLSession
    private let foundationModelService: FoundationModelService

    private struct RequestTuning {
        let reasoningEffort: String?
    }

    private static let lowLatencyReasoningModelIDs: Set<String> = [
        "gpt-5",
        "gpt-5-mini",
        "gpt-5-nano",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
    ]

    private static func requestTuning(for model: ModelConfig, action: ActionConfig) -> RequestTuning {
        let modelID = model.id.lowercased()
        guard lowLatencyReasoningModelIDs.contains(modelID), action.category == .translation else {
            return RequestTuning(reasoningEffort: nil)
        }
        return RequestTuning(reasoningEffort: "minimal")
    }

    public init(
        urlSession: URLSession = NetworkSession.shared,
        foundationModelService: FoundationModelService = .shared
    ) {
        self.urlSession = urlSession
        self.foundationModelService = foundationModelService
    }

    private static let suggestionsRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"\[SUGGESTIONS:\s*(.+?)\]"#,
                options: [.caseInsensitive]
            )
        } catch {
            preconditionFailure("Invalid suggestions regex: \(error)")
        }
    }()

    /// Removes legacy suggestion markers from response text without exposing them as actions.
    static func extractSuggestedActions(from text: String) -> (String, [String]) {
        let fullRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = suggestionsRegex.firstMatch(in: text, options: [], range: fullRange),
              let matchRange = Range(match.range, in: text)
        else {
            return (text, [])
        }

        let stripped = text.replacingCharacters(in: matchRange, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (stripped, [])
    }

    private func extractUpstreamTTFB(from response: HTTPURLResponse) -> TimeInterval? {
        guard let ttfbString = response.value(forHTTPHeaderField: "X-Upstream-TTFB"),
              let ttfbMs = Double(ttfbString), ttfbMs.isFinite, ttfbMs >= 0
        else { return nil }
        return ttfbMs / 1000
    }

    public func perform(
        text: String,
        with action: ActionConfig,
        models: [ModelConfig],
        images: [ImageAttachment] = [],
        targetLanguageDescriptor: String,
        sourceLanguageDescriptor: String = "",
        onboardingTrial: Bool = false,
        refreshEntitlement: Bool = true,
        cachedIsPremium: Bool? = nil,
        timingTraces: [String: TranslationTimingTrace] = [:],
        partialHandler: (@MainActor @Sendable (String, StreamingUpdate) -> Void)? = nil,
        completionHandler: (@MainActor @Sendable (ModelExecutionResult) -> Void)? = nil
    ) async -> [ModelExecutionResult] {
        let hasImages = !images.isEmpty
        return await withTaskGroup(of: ModelExecutionResult?.self) { group in
            for model in models {
                group.addTask { [weak self] in
                    guard let self else { return nil }

                    // Skip models that don't support vision when images are attached
                    if hasImages, !model.supportsVision {
                        return ModelExecutionResult(
                            modelID: model.id,
                            duration: 0,
                            response: .failure(LLMServiceError.visionNotSupported(modelName: model.displayName))
                        )
                    }

                    if model.isFoundationModel {
                        let result = await self.foundationModelService.perform(
                            model: model,
                            text: text,
                            action: action,
                            images: images,
                            targetLanguageDescriptor: targetLanguageDescriptor,
                            sourceLanguageDescriptor: sourceLanguageDescriptor,
                            partialHandler: partialHandler
                        )
                        return Task.isCancelled ? nil : result
                    }

                    do {
                        return try await self.sendModelRequest(
                            text: text,
                            action: action,
                            model: model,
                            images: images,
                            targetLanguageDescriptor: targetLanguageDescriptor,
                            sourceLanguageDescriptor: sourceLanguageDescriptor,
                            onboardingTrial: onboardingTrial,
                            refreshEntitlement: refreshEntitlement,
                            cachedIsPremium: cachedIsPremium,
                            timingTrace: timingTraces[model.id] ?? TranslationTimingTrace(),
                            partialHandler: partialHandler
                        )
                    } catch is CancellationError {
                        return nil
                    } catch {
                        return nil
                    }
                }
            }

            var results: [ModelExecutionResult] = []
            for await item in group {
                guard let item else { continue }
                if let completionHandler {
                    await MainActor.run {
                        completionHandler(item)
                    }
                }
                results.append(item)
            }
            return results
        }
    }

    private func sendModelRequest(
        text: String,
        action: ActionConfig,
        model: ModelConfig,
        images: [ImageAttachment] = [],
        targetLanguageDescriptor: String,
        sourceLanguageDescriptor: String = "",
        onboardingTrial: Bool = false,
        refreshEntitlement: Bool = true,
        cachedIsPremium: Bool? = nil,
        timingTrace: TranslationTimingTrace,
        partialHandler: (@MainActor @Sendable (String, StreamingUpdate) -> Void)?
    ) async throws -> ModelExecutionResult {
        let start = Date()

        let requestURL = CloudServiceConstants.endpoint
            .appendingPathComponent(model.id)
            .appendingPathComponent("chat/completions")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(timingTrace.requestID, forHTTPHeaderField: "X-Request-ID")

        let path = "/\(model.id)/chat/completions"
        CloudAuthHelper.applyAuth(to: &request, path: path)
        if onboardingTrial {
            // The Worker spends this device's trial quota instead of checking
            // premium. Skip premium proof so the trial path is unambiguous in logs.
            let deviceID = try await OnboardingTrialService.deviceID(using: urlSession)
            request.setValue(deviceID, forHTTPHeaderField: "X-Onboarding-Device")
        } else if await hasPremiumEntitlement(
            refresh: refreshEntitlement,
            cachedIsPremium: cachedIsPremium
        ) {
            CloudAuthHelper.applyPremiumProof(to: &request)
        }
        await applyUsageSubjectHeaders(to: &request)

        let structuredOutputConfig = action.structuredOutput
        let enableStreaming = partialHandler != nil
        if enableStreaming {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        let messages: [LLMRequestPayload.Message]
        let imageDataURLs = images.map { $0.base64DataURL }

        let promptMessages = action.promptMessages(
            text: text,
            targetLanguage: targetLanguageDescriptor,
            sourceLanguage: sourceLanguageDescriptor
        )
        if let system = promptMessages.system {
            messages = [
                .init(role: "system", content: system),
                .init(role: "user", text: promptMessages.user, imageDataURLs: imageDataURLs),
            ]
        } else {
            messages = [
                .init(role: "user", text: promptMessages.user, imageDataURLs: imageDataURLs),
            ]
        }

        let requestTuning = Self.requestTuning(for: model, action: action)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = []
            let decoder = JSONDecoder.llmDecoder
            let payloadData: Data

            if let structuredOutputConfig,
               let responseFormat = structuredOutputConfig.responseFormatPayload()
            {
                // For structured output, we must use JSONSerialization to include response_format.
                let messageDicts: [[String: Any]] = messages.map { $0.toDictionary() }

                var body: [String: Any] = [
                    "messages": messageDicts,
                    "stream": enableStreaming,
                ]
                if let reasoningEffort = requestTuning.reasoningEffort {
                    body["reasoning_effort"] = reasoningEffort
                }
                body["response_format"] = responseFormat
                payloadData = try JSONSerialization.data(withJSONObject: body, options: [])
            } else {
                let payload = LLMRequestPayload(
                    messages: messages,
                    stream: enableStreaming ? true : nil,
                    reasoningEffort: requestTuning.reasoningEffort
                )
                payloadData = try encoder.encode(payload)
            }

            request.httpBody = payloadData
            DebugNetworkProtocol.preserveBodyForDebug(in: &request)

            logger.debug(
                """
                Request: model=\(model.displayName, privacy: .public) \
                url=\(requestURL.path, privacy: .public) \
                action=\(action.name, privacy: .public) \
                bytes=\(payloadData.count, privacy: .public)
                """
            )

            try Task.checkCancellation()
            timingTrace.mark(.requestPrepared)

            if enableStreaming, let partialHandler {
                return try await handleModelStreamingRequest(
                    start: start,
                    request: request,
                    model: model,
                    decoder: decoder,
                    structuredOutputConfig: structuredOutputConfig,
                    timingTrace: timingTrace,
                    partialHandler: partialHandler
                )
            } else {
                let (data, response) = try await urlSession.data(for: request)

                let httpResponse = try response.asHTTP(or: URLError(.badServerResponse))
                timingTrace.recordResponseMetadata(httpResponse)
                timingTrace.mark(.streamFinished)

                let responseString = String(data: data, encoding: .utf8) ?? ""
                logger.debug("Response from \(model.displayName, privacy: .public): bytes=\(data.count, privacy: .public)")

                guard (200 ... 299).contains(httpResponse.statusCode) else {
                    throw LLMServiceError.httpError(statusCode: httpResponse.statusCode, body: responseString)
                }

                let parsed = try parseResponsePayload(
                    data: data,
                    structuredOutput: structuredOutputConfig
                )
                let trimmed = parsed.message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw LLMServiceError.emptyContent }
                let (cleanedText, suggestions) = Self.extractSuggestedActions(from: trimmed)
                let duration = Date().timeIntervalSince(start)
                let upstreamTTFB = extractUpstreamTTFB(from: httpResponse)
                return ModelExecutionResult(
                    modelID: model.id,
                    duration: duration,
                    response: .success(cleanedText),
                    diffSource: parsed.diffSource?.trimmingCharacters(in: .whitespacesAndNewlines),
                    supplementalTexts: parsed.supplementalTexts,
                    sentencePairs: parsed.sentencePairs,
                    suggestedActions: suggestions,
                    upstreamTTFB: upstreamTTFB,
                    clientToAzureLatency: nil
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ModelExecutionResult(
                modelID: model.id,
                duration: Date().timeIntervalSince(start),
                response: .failure(error)
            )
        }
    }

    private func handleModelStreamingRequest(
        start: Date,
        request: URLRequest,
        model: ModelConfig,
        decoder: JSONDecoder,
        structuredOutputConfig: ActionConfig.StructuredOutputConfig?,
        timingTrace: TranslationTimingTrace,
        partialHandler: @escaping @MainActor @Sendable (String, StreamingUpdate) -> Void
    ) async throws -> ModelExecutionResult {
        let (bytes, response) = try await urlSession.bytes(for: request)

        try Task.checkCancellation()

        let httpResponse = try response.asHTTP(or: URLError(.badServerResponse))
        timingTrace.receiveHeaders(httpResponse)

        let upstreamTTFBMs = timingTrace.snapshot().upstreamHeaderMilliseconds

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            var errorBytes: [UInt8] = []
            for try await chunk in bytes {
                errorBytes.append(chunk)
            }
            let responseString = String(data: Data(errorBytes), encoding: .utf8) ?? ""
            logger
                .debug("Error response from \(model.displayName, privacy: .public): bytes=\(errorBytes.count, privacy: .public)")
            throw LLMServiceError.httpError(statusCode: httpResponse.statusCode, body: responseString)
        }

        let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let isSentencePairsMode = structuredOutputConfig?.primaryField == ActionConfig.StructuredOutputConfig
            .sentencePairsFieldName
        let isStructuredOutputMode = structuredOutputConfig != nil && !isSentencePairsMode

        if contentType.contains("text/event-stream") {
            logger.debug("Streaming response from \(model.displayName, privacy: .public)")
            var aggregatedText = ""
            let sentencePairParser = isSentencePairsMode ? StreamingSentencePairParser() : nil
            let structuredParser = structuredOutputConfig.flatMap {
                isStructuredOutputMode ? StreamingStructuredOutputParser(config: $0) : nil
            }

            for try await line in bytes.lines {
                try Task.checkCancellation()
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedLine.hasPrefix("data:") else { continue }
                let payload = trimmedLine.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }

                guard let data = payload.data(using: .utf8), !data.isEmpty else { continue }
                let chunk = try decoder.decode(ChatCompletionsStreamChunk.self, from: data)
                let deltaText = chunk.combinedText
                guard !deltaText.isEmpty else { continue }
                timingTrace.receiveContent()
                aggregatedText.append(deltaText)

                if let parser = sentencePairParser {
                    let pairs = parser.append(deltaText)
                    if !pairs.isEmpty {
                        timingTrace.mark(.firstUsefulContent)
                    }
                    await partialHandler(model.id, .sentencePairs(pairs))
                } else if let parser = structuredParser {
                    let displayText = parser.append(deltaText)
                    if !displayText.isEmpty {
                        timingTrace.mark(.firstUsefulContent)
                    }
                    await partialHandler(model.id, .text(displayText))
                } else {
                    timingTrace.mark(.firstUsefulContent)
                    await partialHandler(model.id, .text(aggregatedText))
                }
            }
            timingTrace.mark(.streamFinished)

            let finalText = aggregatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard !finalText.isEmpty else { throw LLMServiceError.emptyContent }

            logger
                .debug(
                    "Final stream output from \(model.displayName, privacy: .public): chars=\(finalText.count, privacy: .public)"
                )

            if isSentencePairsMode {
                let pairs = parseSentencePairsFromJSON(finalText)
                let combinedText = pairs.map { "\($0.original)\n\($0.translation)" }.joined(separator: "\n\n")
                let (cleanedText, suggestions) = Self.extractSuggestedActions(
                    from: combinedText.isEmpty ? finalText : combinedText
                )
                let duration = Date().timeIntervalSince(start)
                let upstream = upstreamTTFBMs.map { $0 / 1000.0 }
                return ModelExecutionResult(
                    modelID: model.id,
                    duration: duration,
                    response: .success(cleanedText),
                    sentencePairs: pairs,
                    suggestedActions: suggestions,
                    upstreamTTFB: upstream,
                    clientToAzureLatency: timingTrace.clientHeaderOverhead
                )
            }

            if let config = structuredOutputConfig {
                let parsed = parseStructuredOutputFromJSON(finalText, config: config)
                if let parsed {
                    let (cleanedMessage, suggestions) = Self.extractSuggestedActions(from: parsed.message)
                    let duration = Date().timeIntervalSince(start)
                    let upstream = upstreamTTFBMs.map { $0 / 1000.0 }
                    return ModelExecutionResult(
                        modelID: model.id,
                        duration: duration,
                        response: .success(cleanedMessage),
                        diffSource: parsed.diffSource,
                        supplementalTexts: parsed.supplementalTexts,
                        sentencePairs: [],
                        suggestedActions: suggestions,
                        upstreamTTFB: upstream,
                        clientToAzureLatency: timingTrace.clientHeaderOverhead
                    )
                }
            }

            let (cleanedFinalText, suggestions) = Self.extractSuggestedActions(from: finalText)
            let duration = Date().timeIntervalSince(start)
            let upstream = upstreamTTFBMs.map { $0 / 1000.0 }
            return ModelExecutionResult(
                modelID: model.id,
                duration: duration,
                response: .success(cleanedFinalText),
                suggestedActions: suggestions,
                upstreamTTFB: upstream,
                clientToAzureLatency: timingTrace.clientHeaderOverhead
            )
        } else {
            var responseBytes: [UInt8] = []
            for try await chunk in bytes {
                try Task.checkCancellation()
                responseBytes.append(chunk)
            }
            timingTrace.mark(.streamFinished)
            let data = Data(responseBytes)

            logger.debug("Non-stream response from \(model.displayName, privacy: .public): bytes=\(data.count, privacy: .public)")

            let parsed = try parseResponsePayload(data: data, structuredOutput: structuredOutputConfig)
            let trimmed = parsed.message.trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard !trimmed.isEmpty else { throw LLMServiceError.emptyContent }

            let (cleanedText, suggestions) = Self.extractSuggestedActions(from: trimmed)

            if !parsed.sentencePairs.isEmpty {
                await partialHandler(model.id, .sentencePairs(parsed.sentencePairs))
            } else {
                try await emitFallbackText(cleanedText, publish: { snapshot in
                    partialHandler(model.id, .text(snapshot))
                })
            }

            return ModelExecutionResult(
                modelID: model.id,
                duration: Date().timeIntervalSince(start),
                response: .success(cleanedText),
                sentencePairs: parsed.sentencePairs,
                suggestedActions: suggestions,
                upstreamTTFB: upstreamTTFBMs.map { $0 / 1000.0 },
                clientToAzureLatency: timingTrace.clientHeaderOverhead
            )
        }
    }

    // MARK: - Conversation Continuation

    /// Sends a continuation message in an ongoing conversation.
    /// Accepts a pre-built messages array (full conversation history) and streams the response.
    /// No structured output / response_format is used for follow-up conversation.
    public func sendContinuation(
        messages: [LLMRequestPayload.Message],
        model: ModelConfig,
        annotationToolHandler: (@MainActor @Sendable (HistoryAnnotationToolRequest) async -> HistoryAnnotationToolResult)? = nil,
        partialHandler: @escaping @MainActor @Sendable (ConversationResponse) -> Void
    ) async throws -> ConversationResponse {
        if model.isFoundationModel {
            guard annotationToolHandler == nil else {
                throw FoundationModelServiceError.annotationToolsNotSupported
            }
            let content = try await foundationModelService.continueConversation(
                messages: messages,
                model: model,
                partialHandler: { content in
                    partialHandler(.init(content: content))
                }
            )
            return .init(content: content)
        }

        if let annotationToolHandler {
            return try await sendToolEnabledContinuation(
                messages: messages,
                model: model,
                annotationToolHandler: annotationToolHandler,
                partialHandler: partialHandler
            )
        }

        var request = await makeContinuationRequest(model: model, acceptsSSE: true)
        let payload = LLMRequestPayload(messages: messages, stream: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        request.httpBody = try encoder.encode(payload)
        DebugNetworkProtocol.preserveBodyForDebug(in: &request)

        logger
            .debug(
                """
                Continuation: model=\(model.displayName, privacy: .public) \
                url=\(request.url?.path ?? "", privacy: .public) \
                messages=\(messages.count, privacy: .public)
                """
            )

        try Task.checkCancellation()

        let (bytes, response) = try await urlSession.bytes(for: request)

        try Task.checkCancellation()

        let httpResponse = try response.asHTTP(or: URLError(.badServerResponse))

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            var errorBytes: [UInt8] = []
            for try await chunk in bytes {
                errorBytes.append(chunk)
            }
            let responseString = String(data: Data(errorBytes), encoding: .utf8) ?? ""
            throw LLMServiceError.httpError(statusCode: httpResponse.statusCode, body: responseString)
        }

        let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let decoder = JSONDecoder.llmDecoder

        if contentType.contains("text/event-stream") {
            var accumulator = ConversationResponseAccumulator()

            for try await line in bytes.lines {
                try Task.checkCancellation()
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedLine.hasPrefix("data:") else { continue }
                let payload = trimmedLine.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }

                guard let data = payload.data(using: .utf8), !data.isEmpty else { continue }
                let chunk = try decoder.decode(ChatCompletionsStreamChunk.self, from: data)
                guard !chunk.combinedText.isEmpty || !chunk.combinedReasoning.isEmpty else { continue }
                let partial = accumulator.append(
                    reasoning: chunk.combinedReasoning,
                    content: chunk.combinedText
                )
                if !partial.reasoning.isEmpty || !partial.content.isEmpty {
                    await partialHandler(partial)
                }
            }

            let response = accumulator.finalResponse()
            guard !response.content.isEmpty else { throw LLMServiceError.emptyContent }
            return response
        } else {
            var responseBytes: [UInt8] = []
            for try await chunk in bytes {
                try Task.checkCancellation()
                responseBytes.append(chunk)
            }
            let data = Data(responseBytes)
            let response = try decodeConversationResponse(data)
            try await emitFallbackResponse(response, partialHandler: partialHandler)
            return response
        }
    }

    public func sendContinuationOnce(
        messages: [LLMRequestPayload.Message],
        model: ModelConfig
    ) async throws -> String {
        var request = await makeContinuationRequest(model: model, acceptsSSE: false)
        request.httpBody = try JSONEncoder().encode(LLMRequestPayload(messages: messages, stream: false))
        DebugNetworkProtocol.preserveBodyForDebug(in: &request)
        let (data, response) = try await urlSession.data(for: request)
        let httpResponse = try response.asHTTP(or: URLError(.badServerResponse))
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? ""
            throw LLMServiceError.httpError(statusCode: httpResponse.statusCode, body: responseString)
        }
        return try decodeConversationResponse(data).content
    }

    private func makeContinuationRequest(model: ModelConfig, acceptsSSE: Bool) async -> URLRequest {
        let requestURL = CloudServiceConstants.endpoint
            .appendingPathComponent(model.id)
            .appendingPathComponent("chat/completions")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if acceptsSSE {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        let path = "/\(model.id)/chat/completions"
        CloudAuthHelper.applyAuth(to: &request, path: path)
        if await hasPremiumEntitlement(refresh: true) {
            CloudAuthHelper.applyPremiumProof(to: &request)
        }
        await applyUsageSubjectHeaders(to: &request)
        return request
    }

    private func sendToolEnabledContinuation(
        messages: [LLMRequestPayload.Message],
        model: ModelConfig,
        annotationToolHandler: @MainActor @Sendable (HistoryAnnotationToolRequest) async -> HistoryAnnotationToolResult,
        partialHandler: @escaping @MainActor @Sendable (ConversationResponse) -> Void
    ) async throws -> ConversationResponse {
        let initialMessages = messages.map { $0.toDictionary() }
        let firstBody: [String: Any] = [
            "messages": initialMessages,
            "tool_choice": "auto",
            "tools": [Self.saveHistoryAnnotationTool],
        ]
        let firstResponse = try await sendStreamingContinuationJSONBody(
            firstBody,
            model: model,
            partialHandler: partialHandler
        )

        guard !firstResponse.toolCalls.isEmpty else {
            guard !firstResponse.response.content.isEmpty else { throw LLMServiceError.emptyContent }
            return firstResponse.response
        }

        var followUpMessages: [[String: Any]] = initialMessages
        followUpMessages.append(Self.assistantToolCallMessageDictionary(toolCalls: firstResponse.toolCalls))
        for toolCall in firstResponse.toolCalls {
            let output = await runHistoryAnnotationTool(toolCall, handler: annotationToolHandler)
            followUpMessages.append([
                "role": "tool",
                "tool_call_id": toolCall.id,
                "content": output,
            ])
        }

        let finalBody: [String: Any] = [
            "messages": followUpMessages,
        ]
        let finalResponse = try await sendStreamingContinuationJSONBody(
            finalBody,
            model: model,
            partialHandler: { response in
                let reasoning = [firstResponse.response.reasoning, response.reasoning]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                partialHandler(.init(reasoning: reasoning, content: response.content))
            }
        )
        guard !finalResponse.response.content.isEmpty else { throw LLMServiceError.emptyContent }
        let reasoning = [firstResponse.response.reasoning, finalResponse.response.reasoning]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return .init(reasoning: reasoning, content: finalResponse.response.content)
    }

    private func sendStreamingContinuationJSONBody(
        _ body: [String: Any],
        model: ModelConfig,
        partialHandler: @escaping @MainActor @Sendable (ConversationResponse) -> Void
    ) async throws -> StreamingContinuationResult {
        var streamingBody = body
        streamingBody["stream"] = true
        var request = await makeContinuationRequest(model: model, acceptsSSE: true)
        request.httpBody = try JSONSerialization.data(withJSONObject: streamingBody, options: [])
        DebugNetworkProtocol.preserveBodyForDebug(in: &request)
        let (bytes, response) = try await urlSession.bytes(for: request)
        let httpResponse = try response.asHTTP(or: URLError(.badServerResponse))
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            var errorBytes: [UInt8] = []
            for try await chunk in bytes {
                errorBytes.append(chunk)
            }
            let responseString = String(data: Data(errorBytes), encoding: .utf8) ?? ""
            throw LLMServiceError.httpError(statusCode: httpResponse.statusCode, body: responseString)
        }

        let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.contains("text/event-stream") else {
            var responseBytes: [UInt8] = []
            for try await chunk in bytes {
                responseBytes.append(chunk)
            }
            let data = Data(responseBytes)
            let response = try JSONDecoder.llmDecoder.decode(ChatCompletionsResponse.self, from: data)
            guard let message = response.choices?.first?.message else {
                throw LLMServiceError.emptyContent
            }
            let conversationResponse = message.conversationResponse()
            if !conversationResponse.content.isEmpty {
                try await emitFallbackResponse(conversationResponse, partialHandler: partialHandler)
            }
            return StreamingContinuationResult(
                response: conversationResponse,
                toolCalls: message.toolCalls ?? []
            )
        }

        var accumulator = ConversationResponseAccumulator()
        var toolCallAccumulator = StreamingToolCallAccumulator()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.hasPrefix("data:") else { continue }
            let payload = trimmedLine.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8), !data.isEmpty else { continue }

            let chunk = try JSONDecoder.llmDecoder.decode(ChatCompletionsStreamChunk.self, from: data)
            toolCallAccumulator.append(chunk.toolCallDeltas)
            guard !chunk.combinedText.isEmpty || !chunk.combinedReasoning.isEmpty else { continue }
            let partial = accumulator.append(
                reasoning: chunk.combinedReasoning,
                content: chunk.combinedText
            )
            if !partial.reasoning.isEmpty || !partial.content.isEmpty {
                await partialHandler(partial)
            }
        }

        return StreamingContinuationResult(
            response: accumulator.finalResponse(),
            toolCalls: toolCallAccumulator.toolCalls
        )
    }

    private func emitFallbackResponse(
        _ response: ConversationResponse,
        partialHandler: @escaping @MainActor @Sendable (ConversationResponse) -> Void
    ) async throws {
        try await emitFallbackText(response.content, publish: { snapshot in
            partialHandler(.init(reasoning: response.reasoning, content: snapshot))
        })
    }

    private func emitFallbackText(
        _ text: String,
        publish: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        try Task.checkCancellation()
        await publish(text)
        try Task.checkCancellation()
    }

    private func runHistoryAnnotationTool(
        _ toolCall: ChatCompletionsResponse.ToolCall,
        handler: @MainActor @Sendable (HistoryAnnotationToolRequest) async -> HistoryAnnotationToolResult
    ) async -> String {
        guard toolCall.function.name == Self.saveHistoryAnnotationToolName else {
            return Self.historyAnnotationToolOutput(.init(success: false, message: "Unknown tool."))
        }
        guard let data = toolCall.function.arguments.data(using: .utf8),
              let arguments = try? JSONDecoder.llmDecoder.decode(SaveHistoryAnnotationArguments.self, from: data)
        else {
            return Self.historyAnnotationToolOutput(.init(success: false, message: "Invalid tool arguments."))
        }
        let result = await handler(.init(targetID: arguments.targetId, markdown: arguments.markdown))
        return Self.historyAnnotationToolOutput(result)
    }

    /// Parse sentence pairs from raw JSON string
    private func parseSentencePairsFromJSON(_ jsonString: String) -> [SentencePair] {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pairsArray = json[ActionConfig.StructuredOutputConfig.sentencePairsFieldName] as? [[String: Any]]
        else {
            return []
        }

        return pairsArray.compactMap { dict -> SentencePair? in
            guard let original = dict["original"] as? String,
                  let translation = dict["translation"] as? String
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

    /// Parse structured output from raw JSON string (e.g., for grammar check)
    private func parseStructuredOutputFromJSON(
        _ jsonString: String,
        config: ActionConfig.StructuredOutputConfig
    ) -> ParsedResponse? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        guard let primaryValue = json[config.primaryField] as? String,
              !primaryValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let trimmedPrimary = primaryValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var supplemental: [String] = []
        for field in config.additionalFields {
            guard let value = json[field] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            supplemental.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var sections = [trimmedPrimary]
        sections.append(contentsOf: supplemental)
        let combined = sections.joined(separator: "\n\n")

        return ParsedResponse(
            message: combined,
            diffSource: trimmedPrimary,
            supplementalTexts: supplemental,
            sentencePairs: []
        )
    }
}

/// Incremental parser for streaming structured output (e.g., grammar check).
/// Extracts field values as they stream in, hiding the JSON structure from the user.
private final class StreamingStructuredOutputParser {
    private var buffer = ""
    private let config: ActionConfig.StructuredOutputConfig
    private let fieldRegex: NSRegularExpression?

    init(config: ActionConfig.StructuredOutputConfig) {
        self.config = config
        let fieldPattern = "\"\(config.primaryField)\"\\s*:\\s*\""
        fieldRegex = try? NSRegularExpression(pattern: fieldPattern, options: [])
    }

    /// Append new delta text and return the display text for UI.
    func append(_ delta: String) -> String {
        buffer.append(delta)
        return extractDisplayText()
    }

    private func extractDisplayText() -> String {
        // Try to extract the primary field value incrementally
        // Look for pattern like "revised_text": "..."
        guard let fieldRegex else {
            return ""
        }

        let nsBuffer = buffer as NSString
        let range = NSRange(location: 0, length: nsBuffer.length)
        guard let match = fieldRegex.firstMatch(in: buffer, options: [], range: range) else {
            return ""
        }

        // Find content after the opening quote
        let contentStart = match.range.upperBound
        guard contentStart < nsBuffer.length else { return "" }

        // UTF-16 character constants
        let backslashChar: unichar = 0x5C // '\'
        let quoteChar: unichar = 0x22 // '"'
        let nChar: unichar = 0x6E // 'n'
        let tChar: unichar = 0x74 // 't'
        let rChar: unichar = 0x72 // 'r'

        // Extract content, handling escaped characters
        var result = ""
        var index = contentStart
        while index < nsBuffer.length {
            let char = nsBuffer.character(at: index)
            if char == backslashChar && index + 1 < nsBuffer.length {
                // Handle escape sequence
                let nextChar = nsBuffer.character(at: index + 1)
                switch nextChar {
                case nChar:
                    result.append("\n")
                case tChar:
                    result.append("\t")
                case rChar:
                    result.append("\r")
                case quoteChar:
                    result.append("\"")
                case backslashChar:
                    result.append("\\")
                default:
                    if let scalar = UnicodeScalar(nextChar) {
                        result.append(Character(scalar))
                    }
                }
                index += 2
            } else if char == quoteChar {
                // End of string value
                break
            } else {
                if let scalar = UnicodeScalar(char) {
                    result.append(Character(scalar))
                }
                index += 1
            }
        }

        return result
    }
}

/// Incremental JSON parser for streaming sentence pairs.
/// Extracts completed sentence pair objects as they become available.
private final class StreamingSentencePairParser {
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

private extension LLMService {
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

        let choices: [Choice]

        var combinedText: String {
            choices.compactMap { $0.delta?.content }.joined()
        }

        var combinedReasoning: String {
            choices.compactMap { $0.delta?.reasoningContent }.joined()
        }

        var toolCallDeltas: [Choice.Delta.ToolCallDelta] {
            choices.flatMap { $0.delta?.toolCalls ?? [] }
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

private extension LLMService.JSONValue {
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
        guard let data = string.data(using: .utf8) else { return nil }
        guard let value = try? JSONDecoder.llmDecoder.decode(LLMService.JSONValue.self, from: data),
              case let .object(object) = value
        else {
            return nil
        }
        return object
    }
}

private extension LLMService.ChatCompletionsResponse.Message {
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

private extension ConversationResponse {
    static func split(reasoning: String, content: String, isFinal: Bool) -> ConversationResponse {
        let firstContentIndex = content.firstIndex { !$0.isWhitespace } ?? content.endIndex
        let candidate = content[firstContentIndex...]
        let openingTag = "<think>"

        if !isFinal, candidate.count < openingTag.count, openingTag.hasPrefix(candidate) {
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

private extension LLMService {
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

private extension JSONDecoder {
    static let llmDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

private extension JSONEncoder {
    static let llmEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
