//
//  VoiceActionService.swift
//  ShareCore
//

import Foundation

public enum VoiceActionError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String?)
    case emptyTranscript
    case noModelAvailable

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "Invalid response from server")
        case let .httpError(statusCode, body):
            return String(localized: "Server error (\(statusCode)): \(body ?? String(localized: "Unknown"))")
        case .emptyTranscript:
            return String(localized: "Transcript is empty")
        case .noModelAvailable:
            return String(localized: "No model is enabled. Please enable at least one model in Settings.")
        }
    }
}

public final class VoiceActionService: Sendable {
    public static let shared = VoiceActionService()

    private let urlSession: URLSession

    public init(urlSession: URLSession = NetworkSession.shared) {
        self.urlSession = urlSession
    }

    // MARK: - Public Types

    public struct VoiceActionOption: Identifiable, Sendable {
        public let id: UUID
        public let title: String
        public let description: String
        public let actionConfig: ActionConfig

        public init(title: String, description: String, actionConfig: ActionConfig) {
            id = UUID()
            self.title = title
            self.description = description
            self.actionConfig = actionConfig
        }
    }

    public struct VoiceActionResult: Sendable {
        public let options: [VoiceActionOption]
        public let allowCustomInput: Bool
    }

    // MARK: - API

    public func generateOptions(transcript: String, locale: String) async throws -> VoiceActionResult {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceActionError.emptyTranscript
        }

        let availableModels = (try? await ModelsService.shared.fetchModels(forceRefresh: false)) ?? []
        let isPremium = await Entitlement.shared.refreshAndGetIsPro()
        let modelID = ModelSelectionPolicy.firstCallableCloudModelID(
            enabledIDs: AppPreferences.shared.enabledModelIDs,
            availableModels: availableModels,
            isPro: isPremium
        )
        guard let modelID else {
            throw VoiceActionError.noModelAvailable
        }

        let requestURL = CloudServiceConstants.endpoint
            .appendingPathComponent(modelID)
            .appendingPathComponent("chat/completions")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let path = "/\(modelID)/chat/completions"
        CloudAuthHelper.applyAuth(to: &request, path: path)

        if isPremium {
            request.setValue("true", forHTTPHeaderField: "X-Premium")
        }

        let systemPrompt = Self.buildSystemPrompt(locale: locale)
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": transcript],
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.7,
            "max_tokens": 1000,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await urlSession.data(for: request)

        let httpResponse = try response.asHTTP(or: VoiceActionError.invalidResponse)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw VoiceActionError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        let chatResponse = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let content = chatResponse.choices.first?.message.content,
              let contentData = content.data(using: .utf8)
        else {
            throw VoiceActionError.invalidResponse
        }

        let apiResponse = try JSONDecoder().decode(APIResponse.self, from: contentData)
        return mapResponse(apiResponse, transcript: transcript)
    }

    // MARK: - System Prompt

    private static func buildSystemPrompt(locale: String) -> String {
        """
        You are an assistant that generates translation action configurations for a translation app called TLingo.
        The user will describe a translation action they want in natural language. Generate 2-3 options as structured JSON.

        Each option must have:
        - title: Short name for the action (in the user's language: \(locale))
        - description: One-line description (in the user's language)
        - action_config: Object with:
          - name: Display name for the action
          - prompt: The prompt template. MUST include {text} placeholder. May include {targetLanguage} if relevant.
          - output_type: One of "plain", "diff", "sentencePairs", "grammarCheck"
          - usage_scenes: Array from ["app", "contextRead", "contextEdit"]. Default to all three.

        Respond with a JSON object containing:
        {
          "options": [ { "title": "...", "description": "...", "action_config": { "name": "...", "prompt": "...", "output_type": "...", "usage_scenes": [...] } } ],
          "allow_custom_input": true
        }
        """
    }

    // MARK: - Response Types

    private struct ChatCompletionsResponse: Decodable {
        struct Choice: Decodable {
            let message: ChatMessage
        }

        struct ChatMessage: Decodable {
            let content: String?
        }

        let choices: [Choice]
    }

    private struct APIResponse: Decodable {
        let options: [APIOption]
        let allowCustomInput: Bool

        enum CodingKeys: String, CodingKey {
            case options
            case allowCustomInput = "allow_custom_input"
        }
    }

    private struct APIOption: Decodable {
        let title: String
        let description: String
        let actionConfig: PartialActionConfig

        enum CodingKeys: String, CodingKey {
            case title, description
            case actionConfig = "action_config"
        }
    }

    private struct PartialActionConfig: Decodable {
        let name: String
        let prompt: String
        let outputType: String

        enum CodingKeys: String, CodingKey {
            case name, prompt
            case outputType = "output_type"
        }

        func toActionConfig() -> ActionConfig {
            let output = OutputType(rawValue: outputType) ?? .plain
            return ActionConfig(name: name, prompt: prompt, outputType: output)
        }
    }

    private func mapResponse(_ response: APIResponse, transcript: String) -> VoiceActionResult {
        var options = response.options.map { option in
            VoiceActionOption(
                title: option.title,
                description: option.description,
                actionConfig: option.actionConfig.toActionConfig()
            )
        }

        // Client-side fallback if API returned empty options
        if options.isEmpty {
            let fallback = VoiceActionOption(
                title: String(localized: "Basic Translation Action"),
                description: String(localized: "A translation action based on your description"),
                actionConfig: ActionConfig(
                    name: String(localized: "Custom Action"),
                    prompt: "Based on the user's request: \"\(transcript)\"\n\nTranslate \"{text}\" to {targetLanguage}.",
                    outputType: .plain
                )
            )
            options.append(fallback)
        }

        return VoiceActionResult(options: options, allowCustomInput: response.allowCustomInput || response.options.isEmpty)
    }
}
