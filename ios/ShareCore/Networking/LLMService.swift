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
    private let trialDeviceID: @MainActor @Sendable (URLSession) async throws -> String

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

    public convenience init(
        urlSession: URLSession = NetworkSession.shared,
        foundationModelService: FoundationModelService = .shared
    ) {
        self.init(
            urlSession: urlSession,
            foundationModelService: foundationModelService,
            trialDeviceID: { try await OnboardingTrialService.deviceID(using: $0) }
        )
    }

    init(
        urlSession: URLSession,
        foundationModelService: FoundationModelService = .shared,
        trialDeviceID: @escaping @MainActor @Sendable (URLSession) async throws -> String
    ) {
        self.urlSession = urlSession
        self.foundationModelService = foundationModelService
        self.trialDeviceID = trialDeviceID
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

                    let start = Date()
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
                        return ModelExecutionResult(
                            modelID: model.id,
                            duration: Date().timeIntervalSince(start),
                            response: .failure(error)
                        )
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

        var request: URLRequest
        if model.isCustomEndpoint {
            request = try CustomEndpointService.shared.makeChatRequest()
            request.setValue(timingTrace.requestID, forHTTPHeaderField: "X-Request-ID")
        } else {
            let requestURL = CloudServiceConstants.endpoint
                .appendingPathComponent(model.id)
                .appendingPathComponent("chat/completions")

            request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(timingTrace.requestID, forHTTPHeaderField: "X-Request-ID")
            // Custom action IDs are user-defined, so only built-in IDs are reported.
            request.setValue(
                BuiltInActionCatalog.isBuiltInAction(action) ? action.id : "custom",
                forHTTPHeaderField: "X-TLingo-Action"
            )

            let path = "/\(model.id)/chat/completions"
            CloudAuthHelper.applyAuth(to: &request, path: path)
            if onboardingTrial {
                // The Worker spends this device's trial quota instead of checking
                // premium. Skip premium proof so the trial path is unambiguous in logs.
                let deviceID = try await trialDeviceID(urlSession)
                request.setValue(deviceID, forHTTPHeaderField: "X-Onboarding-Device")
            } else if await hasPremiumEntitlement(
                refresh: refreshEntitlement,
                cachedIsPremium: cachedIsPremium
            ) {
                CloudAuthHelper.applyPremiumProof(to: &request)
            }
            await applyUsageSubjectHeaders(to: &request)
        }

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

            request.httpBody = try CustomEndpointService.requestBody(payloadData, for: model)
            DebugNetworkProtocol.preserveBodyForDebug(in: &request)

            logger.debug(
                """
                Request: model=\(model.displayName, privacy: .public) \
                url=\(request.url?.path ?? "", privacy: .public) \
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
            var emittedPairCount = 0
            var emittedTextLength = 0

            for try await line in bytes.lines {
                try Task.checkCancellation()
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedLine.hasPrefix("data:") else { continue }
                let payload = trimmedLine.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" {
                    break
                }

                guard let data = payload.data(using: .utf8), !data.isEmpty else { continue }
                let chunk = try ChatCompletionsStreamChunk.decode(data, using: decoder)
                let deltaText = chunk.combinedText
                guard !deltaText.isEmpty else { continue }
                timingTrace.receiveContent()
                aggregatedText.append(deltaText)

                // Deltas that only extend JSON scaffolding leave the visible output unchanged.
                if let parser = sentencePairParser {
                    let pairs = parser.append(deltaText)
                    guard pairs.count != emittedPairCount else { continue }
                    emittedPairCount = pairs.count
                    timingTrace.mark(.firstUsefulContent)
                    await partialHandler(model.id, .sentencePairs(pairs))
                } else if let parser = structuredParser {
                    let displayText = parser.append(deltaText)
                    guard displayText.utf16.count != emittedTextLength else { continue }
                    emittedTextLength = displayText.utf16.count
                    timingTrace.mark(.firstUsefulContent)
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
                diffSource: parsed.diffSource,
                supplementalTexts: parsed.supplementalTexts,
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

        let payload = LLMRequestPayload(messages: messages, stream: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let encodedBody = try encoder.encode(payload)

        logger
            .debug(
                "Continuation: model=\(model.displayName, privacy: .public) messages=\(messages.count, privacy: .public)"
            )

        let result = try await sendStreamingContinuationRequestBody(
            encodedBody,
            model: model,
            partialHandler: partialHandler
        )
        guard !result.response.content.isEmpty else { throw LLMServiceError.emptyContent }
        return result.response
    }

    public func sendContinuationOnce(
        messages: [LLMRequestPayload.Message],
        model: ModelConfig
    ) async throws -> String {
        if model.isFoundationModel {
            return try await foundationModelService.continueConversation(
                messages: messages,
                model: model,
                partialHandler: { _ in }
            )
        }
        var request = try await makeContinuationRequest(model: model, acceptsSSE: false)
        request.httpBody = try CustomEndpointService.requestBody(
            JSONEncoder().encode(LLMRequestPayload(messages: messages, stream: false)),
            for: model
        )
        DebugNetworkProtocol.preserveBodyForDebug(in: &request)
        let (data, response) = try await urlSession.data(for: request)
        let httpResponse = try response.asHTTP(or: URLError(.badServerResponse))
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? ""
            throw LLMServiceError.httpError(statusCode: httpResponse.statusCode, body: responseString)
        }
        return try decodeConversationResponse(data).content
    }

    private func makeContinuationRequest(model: ModelConfig, acceptsSSE: Bool) async throws -> URLRequest {
        if model.isCustomEndpoint {
            var request = try CustomEndpointService.shared.makeChatRequest()
            if acceptsSSE {
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            }
            return request
        }

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
        let rawBody = try JSONSerialization.data(withJSONObject: streamingBody, options: [])
        return try await sendStreamingContinuationRequestBody(
            rawBody,
            model: model,
            partialHandler: partialHandler
        )
    }

    private func sendStreamingContinuationRequestBody(
        _ rawBody: Data,
        model: ModelConfig,
        partialHandler: @escaping @MainActor @Sendable (ConversationResponse) -> Void
    ) async throws -> StreamingContinuationResult {
        var request = try await makeContinuationRequest(model: model, acceptsSSE: true)
        request.httpBody = try CustomEndpointService.requestBody(rawBody, for: model)
        DebugNetworkProtocol.preserveBodyForDebug(in: &request)
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
            if payload == "[DONE]" {
                break
            }
            guard let data = payload.data(using: .utf8), !data.isEmpty else { continue }

            let chunk = try ChatCompletionsStreamChunk.decode(data, using: JSONDecoder.llmDecoder)
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let primaryValue = json[config.primaryField] as? String,
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
