import Combine
import Foundation

@MainActor
public final class ConversationViewModel: ObservableObject {
    @Published public var messages: [ChatMessage]
    @Published public var isStreaming: Bool = false
    @Published public var streamingText: String = ""
    @Published public var streamingReasoningText: String = ""
    @Published public var inputText: String = ""
    @Published public var attachedImages: [ImageAttachment] = []
    @Published public var errorMessage: String?
    @Published public private(set) var requiresPremiumAccess = false

    @Published public var model: ModelConfig {
        didSet {
            guard model.id != oldValue.id else { return }
            preferences.setChatModelID(model.id)
        }
    }

    public let action: ActionConfig
    public let availableModels: [ModelConfig]
    public let markdownStreamSource = ConversationMarkdownStreamSource()
    public let reasoningMarkdownStreamSource = ConversationMarkdownStreamSource()

    private let preferences: AppPreferences
    private let sessionID: UUID
    private let annotationContext: HistoryAnnotationContext?
    private let llmService: LLMService
    private var streamingTask: Task<Void, Never>?
    private var lastStreamingUpdateTime = Date.distantPast
    private var activeRequestSourceText: String?
    private var activeRequestStartedAt: Date?

    public convenience init(session: ConversationSession, llmService: LLMService = .shared) {
        self.init(session: session, llmService: llmService, preferences: .shared)
    }

    init(
        session: ConversationSession,
        llmService: LLMService,
        preferences: AppPreferences
    ) {
        self.preferences = preferences
        sessionID = session.id
        messages = session.messages
        action = session.action
        availableModels = session.availableModels
        model = session.availableModels.first { $0.id == preferences.chatModelID } ?? session.model
        annotationContext = session.annotationContext
        self.llmService = llmService

        // If the session has a pending follow-up, pre-fill input and auto-send
        if let pending = session.pendingInput, !pending.isEmpty {
            inputText = pending
            Task { @MainActor [weak self] in
                self?.send()
            }
        }
    }

    deinit {
        streamingTask?.cancel()
    }

    public var canSend: Bool {
        (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty) && !isStreaming
    }

    public func canUseSelectedModel(isPro: Bool) -> Bool {
        isPro || !model.isPremium
    }

    // MARK: - Image Management

    public func addImage(_ image: ImageAttachment) {
        attachedImages.append(image)
    }

    public func removeImage(id: UUID) {
        attachedImages.removeAll { $0.id == id }
    }

    public func clearImages() {
        attachedImages.removeAll()
    }

    /// Cycles to the next available model in the list.
    public func cycleModel() {
        Task {
            let isPro = await Entitlement.shared.refreshAndGetIsPro()
            let selectableModels = availableModels.filter { isPro || !$0.isPremium }
            guard selectableModels.count > 1 else { return }
            if let currentIndex = selectableModels.firstIndex(where: { $0.id == model.id }) {
                let nextIndex = (currentIndex + 1) % selectableModels.count
                model = selectableModels[nextIndex]
            } else if let first = selectableModels.first {
                model = first
            }
        }
    }

    public func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedImages.isEmpty, !isStreaming else { return }
        streamingTask?.cancel()
        requiresPremiumAccess = false
        streamingTask = Task { [weak self] in
            guard let self else { return }
            let isPro = await Entitlement.shared.refreshAndGetIsPro()
            guard !Task.isCancelled else { return }
            guard self.canUseSelectedModel(isPro: isPro) else {
                self.requiresPremiumAccess = true
                return
            }
            self.requiresPremiumAccess = false
            self.send(text: text)
        }
    }

    private func send(text: String) {
        let currentImages = attachedImages
        let startDate = Date()
        beginStreaming(text: text, images: currentImages, startedAt: startDate)

        streamingTask = Task { [weak self] in
            guard let self else { return }
            self.lastStreamingUpdateTime = .distantPast
            var publishedPartial = false
            do {
                // Build the full messages array for the API
                let apiMessages = self.messages.map { msg in
                    LLMRequestPayload.Message(
                        role: msg.role,
                        text: msg.content,
                        imageDataURLs: msg.images.map { $0.base64DataURL }
                    )
                }

                let response = try await self.llmService.sendContinuation(
                    messages: apiMessages,
                    model: self.model,
                    annotationToolHandler: self.historyAnnotationToolHandler,
                    partialHandler: { [weak self] partialResponse in
                        guard let self else { return }
                        let now = Date()
                        guard now.timeIntervalSince(self.lastStreamingUpdateTime) >= 0.066 else { return }
                        self.lastStreamingUpdateTime = now
                        self.publishStreamingResponse(partialResponse)
                        publishedPartial = true
                    }
                )

                await self.completeStreamingResponse(
                    response,
                    sourceText: text,
                    startedAt: startDate,
                    publishedPartial: publishedPartial
                )
            } catch is CancellationError {
                self.finishStreaming()
            } catch {
                self.errorMessage = error.localizedDescription
                self.finishStreaming()
            }
        }
    }

    public func stopStreaming() {
        guard isStreaming else { return }
        streamingTask?.cancel()
        streamingTask = nil

        let sourceText = activeRequestSourceText ?? messages.last(where: { $0.role == "user" })?.content ?? ""
        let startedAt = activeRequestStartedAt ?? Date()
        let partialContent = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        var assistantMessage: ChatMessage?
        if !partialContent.isEmpty {
            let partialReasoning = streamingReasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
            assistantMessage = ChatMessage(
                role: "assistant",
                content: partialContent,
                reasoning: partialReasoning.isEmpty ? nil : partialReasoning
            )
        }

        finishStreaming()
        if let assistantMessage {
            messages.append(assistantMessage)
        }
        saveConversationResult(
            sourceText: sourceText,
            resultText: partialContent,
            startedAt: startedAt
        )
    }

    private func beginStreaming(text: String, images: [ImageAttachment], startedAt: Date) {
        inputText = ""
        attachedImages.removeAll()
        errorMessage = nil
        messages.append(ChatMessage(role: "user", content: text, images: images))
        activeRequestSourceText = text
        activeRequestStartedAt = startedAt
        isStreaming = true
        streamingText = ""
        streamingReasoningText = ""
        markdownStreamSource.reset()
        reasoningMarkdownStreamSource.reset()
    }

    private func publishStreamingResponse(_ response: ConversationResponse) {
        streamingText = response.content
        streamingReasoningText = response.reasoning
        markdownStreamSource.yield(response.content)
        reasoningMarkdownStreamSource.yield(response.reasoning)
    }

    private func revealStreamingResponse(_ response: ConversationResponse) async {
        publishStreamingResponse(.init(reasoning: response.reasoning, content: ""))
        let characterCount = response.content.count
        for endOffset in stride(from: 16, through: characterCount + 15, by: 16) {
            guard !Task.isCancelled else { return }
            let endIndex = response.content.index(
                response.content.startIndex,
                offsetBy: min(endOffset, characterCount)
            )
            publishStreamingResponse(.init(
                reasoning: response.reasoning,
                content: String(response.content[..<endIndex])
            ))
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func completeStreamingResponse(
        _ response: ConversationResponse,
        sourceText: String,
        startedAt: Date,
        publishedPartial: Bool
    ) async {
        if publishedPartial {
            publishStreamingResponse(response)
        } else {
            await revealStreamingResponse(response)
        }
        let assistantMessage = ChatMessage(
            role: "assistant",
            content: response.content,
            reasoning: response.reasoning.isEmpty ? nil : response.reasoning
        )
        finishStreaming()
        messages.append(assistantMessage)
        saveConversationResult(
            sourceText: sourceText,
            resultText: response.content,
            startedAt: startedAt
        )
    }

    private func saveConversationResult(
        sourceText: String,
        resultText: String,
        startedAt: Date
    ) {
        TranslationHistoryService.shared.save(
            requestID: sessionID,
            sourceText: sourceText,
            resultText: resultText,
            actionName: action.name,
            targetLanguage: "",
            modelID: model.id,
            modelDisplayName: model.displayName,
            duration: Date().timeIntervalSince(startedAt),
            isConversation: true,
            conversationMessages: messages
        )
    }

    private func finishStreaming() {
        markdownStreamSource.finish()
        reasoningMarkdownStreamSource.finish()
        streamingText = ""
        streamingReasoningText = ""
        activeRequestSourceText = nil
        activeRequestStartedAt = nil
        isStreaming = false
    }

    private var historyAnnotationToolHandler: (
        @MainActor @Sendable (HistoryAnnotationToolRequest) async
            -> HistoryAnnotationToolResult
    )? {
        guard let annotationContext else { return nil }
        return { [weak self] request in
            guard let self else {
                return .init(success: false, message: "Conversation is no longer available.")
            }
            return self.saveHistoryAnnotation(request, context: annotationContext)
        }
    }

    private func saveHistoryAnnotation(
        _ request: HistoryAnnotationToolRequest,
        context: HistoryAnnotationContext
    ) -> HistoryAnnotationToolResult {
        guard let targetID = UUID(uuidString: request.targetID), context.targetIDs.contains(targetID) else {
            return .init(success: false, message: "Target ID is not part of this history record.")
        }

        do {
            try TranslationHistoryService.shared.saveAnnotation(
                recordID: context.recordID,
                targetID: targetID,
                markdown: request.markdown
            )
            return .init(success: true, message: "Annotation saved.")
        } catch {
            return .init(success: false, message: error.localizedDescription)
        }
    }
}
