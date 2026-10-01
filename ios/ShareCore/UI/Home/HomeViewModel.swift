//
//  HomeViewModel.swift
//  TLingo
//
//  Created by Zander Wang on 2025/10/19.
//
import Combine
import Foundation
import os
import SwiftUI

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "HomeViewModel")
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif
#if canImport(Translation)
    import Translation
#endif

@MainActor
public final class HomeViewModel: ObservableObject {
    struct RequestGenerationTracker {
        private(set) var activeGeneration: UUID?
        private(set) var runTokens: [String: UUID] = [:]

        mutating func begin(generation: UUID, runTokens: [String: UUID]) {
            activeGeneration = generation
            self.runTokens = runTokens
        }

        mutating func retry(runID: String, token: UUID) {
            runTokens[runID] = token
        }

        mutating func cancel() {
            activeGeneration = nil
            runTokens.removeAll()
        }

        func accepts(generation: UUID, runID: String, token: UUID) -> Bool {
            activeGeneration == generation && runTokens[runID] == token
        }
    }

    enum RequestTaskOwner: Equatable {
        case primary
        case retry(runID: String, runToken: UUID)
    }

    enum RequestTaskCleanup: Equatable {
        case none
        case primary
        case retry(runID: String)
    }

    nonisolated static func taskCleanup(
        for owner: RequestTaskOwner,
        generationMatches: Bool,
        retryMatches: Bool
    ) -> RequestTaskCleanup {
        guard generationMatches else { return .none }
        switch owner {
        case .primary:
            return .primary
        case let .retry(runID, _):
            return retryMatches ? .retry(runID: runID) : .none
        }
    }

    @Published public var selectedDebugNetworkRecord: NetworkRequestRecord?
    public struct ModelRunViewState: Identifiable {
        public struct SuccessResult {
            public let text: String
            public let copyText: String
            public let duration: TimeInterval
            public var diff: TextDiffBuilder.Presentation?
            public var supplementalTexts: [String]
            public var sentencePairs: [SentencePair]
            public var latencyBreakdown: LatencyBreakdown?
            public var suggestedActions: [String]

            public init(
                text: String,
                copyText: String,
                duration: TimeInterval,
                diff: TextDiffBuilder.Presentation? = nil,
                supplementalTexts: [String] = [],
                sentencePairs: [SentencePair] = [],
                latencyBreakdown: LatencyBreakdown? = nil,
                suggestedActions: [String] = []
            ) {
                self.text = text
                self.copyText = copyText
                self.duration = duration
                self.diff = diff
                self.supplementalTexts = supplementalTexts
                self.sentencePairs = sentencePairs
                self.latencyBreakdown = latencyBreakdown
                self.suggestedActions = suggestedActions
            }
        }

        public enum Status {
            case idle
            case running(start: Date)
            case streaming(text: String, start: Date)
            case streamingSentencePairs(pairs: [SentencePair], start: Date)
            case success(SuccessResult)
            case failure(message: String, duration: TimeInterval, responseBody: String? = nil)

            public var duration: TimeInterval? {
                switch self {
                case .idle, .running, .streaming, .streamingSentencePairs:
                    return nil
                case let .success(result):
                    return result.duration
                case let .failure(_, duration, _):
                    return duration
                }
            }

            public var latencyBreakdown: LatencyBreakdown? {
                switch self {
                case let .success(result):
                    return result.latencyBreakdown
                default:
                    return nil
                }
            }
        }

        public struct LatencyBreakdown {
            /// Azure Functions ↔ Model (upstream TTFB)
            public let upstreamTTFB: TimeInterval
            /// Client ↔ Azure Functions (estimated)
            public let clientToAzure: TimeInterval
            /// Detailed network timing from URLSessionTaskMetrics
            public let networkMetrics: NetworkTimingMetrics?

            public var upstreamText: String {
                formatLatency(upstreamTTFB)
            }

            public var clientToAzureText: String {
                formatLatency(clientToAzure)
            }

            private func formatLatency(_ value: TimeInterval) -> String {
                if value < 1 {
                    return String(format: "%.0fms", value * 1000)
                }
                return String(format: "%.1fs", value)
            }
        }

        /// How a translation run is shown; sentence pairs are fetched per run on demand.
        public enum Presentation: Hashable {
            case standard
            case sentencePairs
        }

        public let model: ModelConfig
        public let markdownStreamSource = ConversationMarkdownStreamSource()
        public var status: Status
        public var presentation: Presentation = .standard
        /// Finished status per presentation, so switching back never re-requests.
        var cachedStatuses: [Presentation: Status] = [:]
        public var showDiff: Bool = true
        /// When this run first showed output; fixes its slot in first-result order.
        public var firstOutputAt: Date?

        public var id: String { model.id }

        public var modelDisplayName: String { model.displayName }

        public var durationText: String? {
            guard let duration = status.duration else { return nil }
            return String(format: "%.1fs", duration)
        }

        public var isRunning: Bool {
            switch status {
            case .running, .streaming, .streamingSentencePairs:
                return true
            default:
                return false
            }
        }

        public var startDate: Date? {
            switch status {
            case let .running(start), let .streaming(_, start), let .streamingSentencePairs(_, start):
                return start
            default:
                return nil
            }
        }
    }

    @Published public var inputText: String = "" {
        didSet {
            guard inputText != oldValue else { return }
            cancelActiveRequest(clearResults: true)
            scheduleLanguagePreviewRefresh()
        }
    }

    /// Timestamp of the last user-originated edit to `inputText`. Set only by
    /// UI input paths (e.g. text view delegate), never by programmatic writes,
    /// so callers can distinguish in-progress user input from auto-filled text.
    public var lastUserEditAt: Date?

    /// Mark that the current `inputText` was just modified by the user.
    public func markUserEditedInput() {
        lastUserEditAt = Date()
    }

    /// Reset the user-edit marker (e.g. after a programmatic overwrite that
    /// should not count as a user edit for future overwrite-protection checks).
    public func clearUserEditMark() {
        lastUserEditAt = nil
    }

    @Published public var attachedImages: [ImageAttachment] = [] {
        didSet {
            guard attachedImages.count != oldValue.count else { return }
            cancelActiveRequest(clearResults: true)
        }
    }

    public func addImage(_ image: ImageAttachment) {
        attachedImages.append(image)
    }

    public func removeImage(id: UUID) {
        attachedImages.removeAll { $0.id == id }
    }

    public func clearImages() {
        attachedImages.removeAll()
    }

    @Published public private(set) var actions: [ActionConfig]
    @Published public private(set) var models: [ModelConfig] = []
    @Published public private(set) var isLoadingModels = false
    /// Cached catalogs can be stale, so enabled model IDs are reconciled only against a server response.
    private var hasFetchedModels = false
    @Published public var selectedActionID: UUID?
    @Published public private(set) var modelRuns: [ModelRunViewState] = []

    public var displayedModelRuns: [ModelRunViewState] {
        Self.sortModelRuns(
            modelRuns,
            order: preferences.modelResultOrder,
            catalog: ModelListSections.resultOrder(cloudModels: models)
        )
    }

    public static func sortModelRuns(
        _ runs: [ModelRunViewState],
        order: ModelResultOrder,
        catalog: [ModelConfig]
    ) -> [ModelRunViewState] {
        let ranks = Dictionary(
            catalog.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return runs.enumerated().sorted { lhs, rhs in
            if order == .firstCompletedFirst {
                // Runs keep their slot once output appears, even if they later fail.
                switch (lhs.element.firstOutputAt, rhs.element.firstOutputAt) {
                case let (left?, right?):
                    if left != right {
                        return left < right
                    }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    let leftFailed = if case .failure = lhs.element.status {
                        true
                    } else {
                        false
                    }
                    let rightFailed = if case .failure = rhs.element.status {
                        true
                    } else {
                        false
                    }
                    if leftFailed != rightFailed {
                        return !leftFailed
                    }
                }
            }
            let leftRank = ranks[lhs.element.id] ?? Int.max
            let rightRank = ranks[rhs.element.id] ?? Int.max
            return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
        }.map(\.element)
    }

    @Published public private(set) var isLoadingConfiguration: Bool = true

    /// When set, `refreshConfiguration()` will select this action after loading.
    public internal(set) var pendingDeepLinkActionName: String?

    /// Non-nil when the target used for the current request differs from
    /// the persisted target preference, either because Match resolved to a
    /// concrete language or because the user picked a one-shot override.
    @Published public private(set) var resolvedTargetLanguage: TargetLanguageOption?

    /// The detected (or user-pinned) source language, refreshed live while typing and on each request.
    @Published public private(set) var detectedSourceLanguage: SourceLanguageOption?

    /// True when the automatic target skipped the first language because the source already is that language.
    @Published public private(set) var isMatchTargetFallback = false

    private var languagePreviewTask: Task<Void, Never>?

    // MARK: - Apple Translation Bridge

    /// When false, Apple Translate is excluded from the model list even if enabled in preferences.
    /// Use the extension path (`TranslationSession(installedSource:target:)`) which requires pre-installed packs.
    public let supportsAppleTranslate: Bool

    /// When non-empty, the view model runs in "onboarding trial" mode: every
    /// request is forced to use these models and is sent with the
    /// `onboardingTrial` flag so the Worker can bypass the premium
    /// entitlement check. Used by `OnboardingTrialSheet` so a user can preview
    /// premium models before being shown the paywall.
    public let onboardingTrialModels: [ModelConfig]

    /// Published by the view model to request a `.translationTask()` session from the view layer.
    /// HomeView observes this and creates a `TranslationSession.Configuration`.
    @Published public var appleTranslateTargetLanguage: TargetLanguageOption?

    /// Detected source language for the pending Apple Translate request.
    /// Used by HomeView to set `TranslationSession.Configuration.source`
    /// so the system does not show a "Choose Language" prompt.
    public private(set) var appleTranslateSourceLanguage: Locale.Language?

    /// Context captured when an Apple Translate request is pending, so that the
    /// `.translationTask()` callback in HomeView can relay it back.
    public private(set) var pendingAppleTranslateText: String?
    public private(set) var pendingAppleTranslateAction: ActionConfig?
    public private(set) var pendingAppleTranslateRequestID: UUID?
    private var pendingAppleTranslateResolvedTarget: TargetLanguageOption?

    /// When non-nil, bypasses automatic language detection and uses this
    /// target language for the current translation.
    private var targetLanguageOverride: TargetLanguageOption?

    /// Optional handler invoked on macOS to route Apple Translate requests through a
    /// real NSWindow (required for TranslationSession to work outside an NSPopover).
    /// Set by the host app (AITranslator) via `AppleTranslationWindowManager`.
    public var appleTranslationRequestHandler: ((Locale.Language?, TargetLanguageOption) -> Void)?

    // MARK: - TTS Playback State

    @Published public private(set) var speakingModels: Set<String> = []
    @Published public private(set) var isSpeakingInputText: Bool = false
    /// Set to `true` when the user triggers an action but has not yet accepted data sharing consent.
    @Published public var showDataConsentRequest: Bool = false
    /// Set to `true` when the satisfaction prompt toast should be displayed.
    @Published public var showSatisfactionPrompt: Bool = false
    /// Incremented each time a translation request completes with at least one success.
    @Published public private(set) var successfulTranslationCount: Int = 0
    private let ttsService: TTSPreviewService

    public let placeholderHint: String = NSLocalizedString(
        "Enter text and choose an action to get started",
        comment: "Hint shown above the action list when no input or results exist"
    )
    public let inputPlaceholder: String = NSLocalizedString(
        "Enter text to translate or process...",
        comment: "Placeholder text for the main input editor"
    )

    private let configurationStore: AppConfigurationStore
    private let llmService: LLMService
    private let preferences: AppPreferences
    private var cancellables = Set<AnyCancellable>()
    private var currentRequestTask: Task<Void, Never>?
    private var activeRequestContext: RequestContext?
    private var requestGenerationTracker = RequestGenerationTracker()

    // Per-run retry support (so tapping retry on one card doesn't re-run every model)
    private var perRunTasks: [String: Task<Void, Never>] = [:]
    private var allActions: [ActionConfig]
    public private(set) var currentRequestInputText: String = ""
    private var currentRequestImages: [ImageAttachment] = []
    /// Timestamp-based throttle for streaming UI updates (~15Hz).
    private var lastStreamingUpdateTime: [String: Date] = [:]
    /// When true, `performSelectedAction()` will be called automatically once models finish loading.
    private var pendingAutoAction: Bool = false

    private struct RequestContext {
        let generation: UUID
        let historyRequestID: UUID
        let text: String
        let images: [ImageAttachment]
        let action: ActionConfig
        let languages: ResolvedLanguagePair
        let showsDiff: Bool
        let refreshEntitlement: Bool
        let cachedIsPremium: Bool
        /// History record for on-demand sentence-pair runs, kept apart from the main result.
        var sentencePairsHistoryRequestID = UUID()

        func withAction(_ action: ActionConfig, historyRequestID: UUID) -> RequestContext {
            var context = RequestContext(
                generation: generation,
                historyRequestID: historyRequestID,
                text: text,
                images: images,
                action: action,
                languages: languages,
                showsDiff: action.showsDiff,
                refreshEntitlement: refreshEntitlement,
                cachedIsPremium: cachedIsPremium
            )
            context.sentencePairsHistoryRequestID = sentencePairsHistoryRequestID
            return context
        }
    }

    private var pendingAppleTranslateContext: RequestContext?
    private var pendingAppleTranslateRunToken: UUID?

    // MARK: - Snapshot Mode

    /// Returns `true` when the app is launched with `-FASTLANE_SNAPSHOT`
    /// (used by Fastlane's snapshot tool to capture App Store screenshots).
    public static var isSnapshotMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-FASTLANE_SNAPSHOT")
    }

    /// Returns `true` when the app should auto-present the conversation
    /// sheet for screenshot capture.
    public static var isSnapshotConversationMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-SNAPSHOT_CONVERSATION")
    }

    public init(
        configurationStore: AppConfigurationStore? = nil,
        llmService: LLMService = .shared,
        preferences: AppPreferences = .shared,
        ttsService: TTSPreviewService = .shared,
        supportsAppleTranslate: Bool = true,
        onboardingTrialModels: [ModelConfig] = []
    ) {
        let store = configurationStore ?? .shared
        self.configurationStore = store
        self.llmService = llmService
        self.preferences = preferences
        self.ttsService = ttsService
        self.supportsAppleTranslate = supportsAppleTranslate
        self.onboardingTrialModels = onboardingTrialModels
        allActions = store.actions
        selectedActionID = store.defaultAction?.id
        actions = []
        isLoadingConfiguration = true

        if Self.isSnapshotMode {
            populateSnapshotData()
        } else {
            refreshActions()
            loadModels()

            store.$actions
                .receive(on: RunLoop.main)
                .sink { [weak self] in
                    guard let self else { return }
                    self.allActions = $0
                    self.refreshActions()
                }
                .store(in: &cancellables)

            preferences.$enabledModelIDs
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.updateEnabledModels()
                }
                .store(in: &cancellables)
        }

        isLoadingConfiguration = false

        Publishers.Merge(
            preferences.$sourceLanguage.dropFirst().map { _ in () },
            preferences.$targetLanguage.dropFirst().map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            self?.scheduleLanguagePreviewRefresh()
        }
        .store(in: &cancellables)

        preferences.$modelResultOrder
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Snapshot Mock Data

    /// Populates the view model with realistic-looking mock data for
    /// Fastlane App Store screenshot capture.
    private func populateSnapshotData() {
        let fixture = SnapshotLaunchArguments.fixture() ?? .multiModelTranslation
        let snapshotLocale = SnapshotLocaleCatalog.current()

        let translateAction = ActionConfig(
            name: NSLocalizedString("Translate", comment: ""),
            prompt: SnapshotFixtureData.translatePrompt(for: fixture),
            outputType: .translate
        )
        let grammarAction = ActionConfig(
            name: NSLocalizedString("Grammar Check", comment: ""),
            prompt: "Check grammar",
            outputType: .grammarCheck
        )
        let polishAction = ActionConfig(
            name: NSLocalizedString("Polish Writing", comment: ""),
            prompt: "Polish the writing",
            outputType: .diff
        )

        allActions = [translateAction, grammarAction, polishAction]
        actions = [translateAction, grammarAction, polishAction]
        models = SnapshotFixtureData.cloudModels(for: fixture)

        if let actionName = SnapshotLaunchArguments.value(after: "-SNAPSHOT_ACTION") {
            switch actionName.lowercased() {
            case "grammar": selectedActionID = grammarAction.id
            case "polish": selectedActionID = polishAction.id
            default: selectedActionID = translateAction.id
            }
        } else {
            selectedActionID = translateAction.id
        }

        preferences.setSourceLanguage(.english, reason: "Snapshot fixture")
        preferences.setTargetLanguage(snapshotLocale.targetLanguage, reason: "Snapshot fixture")
        preferences.setAppleTranslateInstalledLanguages([
            SourceLanguageOption.english.rawValue,
            snapshotLocale.targetLanguage.rawValue,
        ])

        switch fixture {
        case .offlineAppleTranslation:
            preferences.setEnabledModelIDs(SnapshotFixtureData.enabledModelIDs(for: fixture))
        case .multiModelTranslation, .realtimeBilingualLive, .realtimeAppleValidation,
             .aiModels, .macRealtimeMultiLane,
             .macRichConversation, .macHistoryChat:
            let enabledIDs = SnapshotFixtureData.enabledModelIDs(for: .multiModelTranslation)
            if !enabledIDs.isEmpty {
                preferences.setEnabledModelIDs(enabledIDs)
            }
        }

        let wantsGrammarCheck = selectedActionID == grammarAction.id
        inputText = wantsGrammarCheck
            ? SnapshotLocaleCatalog.grammarSourceText
            : SnapshotFixtureData.inputText

        currentRequestInputText = inputText

        let wantsDiff = (selectedActionID == polishAction.id)
        if wantsDiff {
            let polishedResults = SnapshotLocaleCatalog.writingPolishedResults
            let modelIDs = ["gpt-5.4", "DeepSeek-V4-Pro", "Kimi-K2.6"]
            modelRuns = modelIDs.enumerated().compactMap { index, modelID in
                guard let model = SnapshotFixtureData.cloudModels.first(where: { $0.id == modelID }),
                      let text = polishedResults[modelID]
                else {
                    return nil
                }
                return ModelRunViewState(
                    model: model,
                    status: .success(ModelRunViewState.SuccessResult(
                        text: text,
                        copyText: text,
                        duration: 0.9 + TimeInterval(index) * 0.2,
                        diff: TextDiffBuilder.build(original: inputText, revised: text)
                    ))
                )
            }
            return
        }

        if wantsGrammarCheck {
            let result = "\(SnapshotLocaleCatalog.grammarCorrectedText)\n\n\(snapshotLocale.grammarExplanation)"
            let model = SnapshotFixtureData.cloudModels.first { $0.id == "gpt-5-nano" } ?? ModelConfig.appleTranslate
            modelRuns = [
                ModelRunViewState(
                    model: model,
                    status: .success(ModelRunViewState.SuccessResult(
                        text: result,
                        copyText: result,
                        duration: 0.9
                    ))
                ),
            ]
            return
        }

        modelRuns = SnapshotFixtureData.resultModels(for: fixture).enumerated().map { index, model in
            let text = SnapshotFixtureData.resultText(for: model, fixture: fixture)
            return ModelRunViewState(
                model: model,
                status: .success(ModelRunViewState.SuccessResult(
                    text: text,
                    copyText: text,
                    duration: 0.8 + TimeInterval(index) * 0.2
                ))
            )
        }
    }

    /// Creates a pre-built ``ConversationSession`` for snapshot mode,
    /// so the conversation sheet can be presented immediately without
    /// needing to tap a UI button.
    ///
    /// Builds a 4-message conversation:
    /// 1. User (locale language): "The quick brown fox..." pangram
    /// 2. Assistant (English): English translation
    /// 3. User (locale language): "Make it shorter"
    /// 4. Assistant (English): Shortened version
    public func createSnapshotConversationSession() -> ConversationSession? {
        guard let firstRun = modelRuns.first,
              let action = selectedAction else { return nil }

        let fixture = SnapshotLaunchArguments.fixture() ?? .multiModelTranslation
        let messages = fixture == .macRichConversation
            ? SnapshotFixtureData.macConversationMessages()
            : [
                ChatMessage(role: "user", content: SnapshotFixtureData.inputText),
                ChatMessage(
                    role: "assistant",
                    content: SnapshotFixtureData.resultText(for: firstRun.model, fixture: .multiModelTranslation)
                ),
            ]
        let conversationModel = fixture == .macRichConversation
            ? (SnapshotFixtureData.cloudModels.first(where: { $0.id == "gpt-5.4" }) ?? firstRun.model)
            : firstRun.model
        let conversationModels = fixture == .macRichConversation
            ? SnapshotFixtureData.cloudModels
            : models

        return ConversationSession(
            model: conversationModel,
            action: action,
            availableModels: conversationModels,
            messages: messages
        )
    }

    public var defaultAction: ActionConfig? {
        actions.first
    }

    // MARK: - State Snapshot (cross-window sync)

    /// A minimal snapshot of the user-visible translation state, used to hand off
    /// in-flight translation context (input + selected action + results) from one
    /// HomeViewModel instance to another (e.g. menu bar popover → main window).
    public struct StateSnapshot {
        public let inputText: String
        public let currentRequestInputText: String
        public let selectedActionID: UUID?
        public let modelRuns: [ModelRunViewState]

        public init(
            inputText: String,
            currentRequestInputText: String,
            selectedActionID: UUID?,
            modelRuns: [ModelRunViewState]
        ) {
            self.inputText = inputText
            self.currentRequestInputText = currentRequestInputText
            self.selectedActionID = selectedActionID
            self.modelRuns = modelRuns
        }
    }

    public func captureStateSnapshot() -> StateSnapshot {
        StateSnapshot(
            inputText: inputText,
            currentRequestInputText: currentRequestInputText,
            selectedActionID: selectedActionID,
            modelRuns: modelRuns
        )
    }

    /// Adopt a snapshot from another HomeViewModel. Cancels any in-flight requests,
    /// overwrites input/action/results, but does NOT trigger a new translation.
    public func adoptStateSnapshot(_ snapshot: StateSnapshot) {
        cancelActiveRequest(clearResults: true)
        // Assign inputText first — its didSet calls cancelActiveRequest(clearResults: true)
        // which would wipe modelRuns if assigned afterwards.
        inputText = snapshot.inputText
        clearUserEditMark()
        currentRequestInputText = snapshot.currentRequestInputText
        if let id = snapshot.selectedActionID {
            selectedActionID = id
        }
        // Source ViewModel owned the in-flight URLSession tasks; once we adopt
        // the snapshot here those tasks keep streaming into the *source* and
        // never update us. Materialize any non-terminal run as a cancellation
        // so the UI doesn't show a perpetual spinner.
        modelRuns = snapshot.modelRuns.map { run in
            switch run.status {
            case .idle, .running, .streaming, .streamingSentencePairs:
                let elapsed: TimeInterval = {
                    switch run.status {
                    case let .running(start),
                         let .streaming(_, start),
                         let .streamingSentencePairs(_, start):
                        return Date().timeIntervalSince(start)
                    default:
                        return 0
                    }
                }()
                var copy = run
                copy.status = .failure(
                    message: NSLocalizedString("Cancelled", comment: "Run cancelled by handoff to main window"),
                    duration: elapsed,
                    responseBody: nil
                )
                return copy
            case .success, .failure:
                return run
            }
        }
    }

    public var selectedAction: ActionConfig? {
        guard let id = selectedActionID else {
            return actions.first
        }
        return actions.first(where: { $0.id == id }) ?? actions.first
    }

    public func refreshConfiguration() {
        isLoadingConfiguration = true

        configurationStore.reloadCurrentConfiguration()

        allActions = configurationStore.actions
        refreshActions()
        loadModels()
        logger
            .debug(
                "refreshConfiguration() — \(self.actions.count, privacy: .public) actions: \(self.actions.map(\.name), privacy: .public)"
            )

        // Apply pending deep link action, or fall back to first action
        if let pendingName = pendingDeepLinkActionName,
           let action = actions.first(where: { $0.name == pendingName })
        {
            selectedActionID = action.id
            pendingDeepLinkActionName = nil
        } else if let firstAction = actions.first {
            selectedActionID = firstAction.id
        }

        isLoadingConfiguration = false
    }

    /// Handles a deep link from the extension: switches config if needed, selects action, and runs.
    public func applyDeepLink(text: String, actionName: String?, configName: String?) {
        inputText = text

        // Switch configuration if the deep link specifies a different one
        if let configName,
           configurationStore.currentConfigurationName != configName
        {
            configurationStore.setCurrentConfigurationName(configName)
        }

        // Reload to pick up the (possibly switched) configuration
        refreshConfiguration()

        // Try to select the action by name now; also store as pending for cold launch
        pendingDeepLinkActionName = actionName
        if let actionName,
           let action = actions.first(where: { $0.name == actionName })
        {
            _ = selectAction(action)
            pendingDeepLinkActionName = nil
        }

        performSelectedAction()
    }

    public var canSend: Bool {
        guard selectedAction != nil else {
            return false
        }
        // Always allow sending — if models aren't loaded yet we queue via
        // pendingAutoAction; if no models match we show an error to the user.
        return true
    }

    /// Direct translation services only translate, so prompt-based actions need an AI model.
    public func requiresAIModelSelection(for action: ActionConfig) -> Bool {
        guard !action.supportsAppleTranslate, onboardingTrialModels.isEmpty, !models.isEmpty else { return false }
        guard preferences.enabledModelIDs.contains(where: ModelConfig.isDirectTranslationID) else { return false }
        return getEnabledModels().allSatisfy(\.isDirectTranslation)
    }

    private func getEnabledModels(
        cachedIsPremium: Bool? = nil,
        allowModelFallback: Bool = false
    ) -> [ModelConfig] {
        // Onboarding trial mode: hard-pin to the model the user picked, skip
        // the entire preferences/premium gating dance so the trial can still
        // run on a premium model even though the user hasn't subscribed yet.
        if !onboardingTrialModels.isEmpty {
            return onboardingTrialModels
        }

        let enabledIDs = preferences.enabledModelIDs
        let isPremium = cachedIsPremium ?? Entitlement.shared.isPro

        logger
            .debug(
                "getEnabledModels: enabledIDs=\(enabledIDs, privacy: .public), models.count=\(self.models.count, privacy: .public), isPremium=\(isPremium, privacy: .public)"
            )

        let modelCatalog = models
        var available: [ModelConfig]
        if enabledIDs.isEmpty {
            available = modelCatalog.filter { $0.isDefault }
        } else {
            available = modelCatalog.filter { enabledIDs.contains($0.id) }
        }

        if !isPremium {
            available = available.filter { !$0.isPremium }
        }

        // Fallback: if all selected models were filtered out (e.g. user downgraded),
        // use the default free model so the send button never silently fails.
        // Skip fallback when a standalone built-in model is selected.
        let builtInModelSelected = enabledIDs.contains {
            ModelConfig.isDirectTranslationID($0) || ModelConfig.isFoundationModelID($0)
        }
        if available.isEmpty, !builtInModelSelected {
            available = modelCatalog.filter { $0.isDefault && !$0.isPremium }
        }
        if available.isEmpty, !builtInModelSelected {
            available = Array(modelCatalog.filter { !$0.isPremium }.prefix(1))
        }

        if enabledIDs.contains(ModelConfig.foundationModelID) {
            available.insert(ModelConfig.foundationModel, at: 0)
        }
        if !BuildEnvironment.isDirectDistribution,
           enabledIDs.contains(ModelConfig.privateCloudModelID)
        {
            available.insert(ModelConfig.privateCloudModel, at: 0)
        }

        // Inject Apple Translate only for translation actions.
        // In SwiftUI contexts (supportsAppleTranslate = true), the view layer provides a session
        // via .translationTask(). In non-SwiftUI contexts (e.g. extension), we fall back to
        // TranslationSession(installedSource:target:) which requires pre-installed language packs.
        if enabledIDs.contains(ModelConfig.appleTranslateID),
           AppleTranslationService.shared.isAvailable,
           let action = selectedAction, action.supportsAppleTranslate
        {
            available.insert(ModelConfig.appleTranslate, at: 0)
        }

        if enabledIDs.contains(ModelConfig.microsoftTranslateID),
           let action = selectedAction, action.supportsAppleTranslate
        {
            // Insert after Apple Translate if present, otherwise at the beginning.
            let insertIndex = available.firstIndex(where: { $0.id == ModelConfig.appleTranslateID })
                .map { available.index(after: $0) } ?? 0
            available.insert(ModelConfig.microsoftTranslate, at: insertIndex)
        }

        // Last resort when neither the server nor the user settings yield a model.
        // `allowModelFallback` callers cannot wait for the catalog request to finish.
        if available.isEmpty, !isLoadingModels || allowModelFallback,
           AppleTranslationService.shared.isAvailable,
           let action = selectedAction, action.supportsAppleTranslate
        {
            available = [ModelConfig.appleTranslate]
        }

        logger.debug("getEnabledModels result: \(available.map(\.id), privacy: .public)")
        return available
    }

    private func loadModels() {
        // Display cached models immediately if available, then refresh in background.
        if let cached = ModelsService.shared.getCachedModels(), !cached.isEmpty {
            models = cached
            logger.debug("loadModels: loaded \(cached.count, privacy: .public) cached models")
        } else {
            logger.debug("loadModels: no cached models, fetching from network")
        }

        isLoadingModels = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let fetchedModels = try await ModelsService.shared.fetchModels(forceRefresh: true)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isLoadingModels = false
                    self.hasFetchedModels = true
                    self.models = fetchedModels
                    logger.debug("loadModels: fetched \(fetchedModels.count, privacy: .public) models from network")
                    self.updateEnabledModels()

                    // If a request was attempted before models loaded, trigger it now.
                    if self.pendingAutoAction {
                        self.pendingAutoAction = false
                        self.performSelectedAction()
                    }
                }
            } catch {
                logger.error("Failed to fetch models: \(error, privacy: .public)")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Keep the cached catalog; getEnabledModels falls back to Apple Translate without one.
                    self.isLoadingModels = false
                    if self.pendingAutoAction {
                        self.pendingAutoAction = false
                        self.performSelectedAction()
                    }
                }
            }
        }
    }

    private func updateEnabledModels() {
        let availableIDs = Set(models.map { $0.id })
        guard hasFetchedModels, !availableIDs.isEmpty else { return }

        let currentEnabled = preferences.enabledModelIDs
        // Preserve built-in model IDs that do not come from the cloud model list.
        let builtInIDs = currentEnabled.filter {
            ModelConfig.isDirectTranslationID($0)
                || (ModelConfig.isFoundationModelID($0)
                    && (!BuildEnvironment.isDirectDistribution || $0 != ModelConfig.privateCloudModelID))
        }
        var resolved = currentEnabled.intersection(availableIDs).union(builtInIDs)
        if resolved.isEmpty {
            let defaults = Set(models.filter { $0.isDefault }.map { $0.id })
            if !defaults.isEmpty {
                resolved = resolved.union(defaults)
            }
        }

        if resolved != currentEnabled {
            preferences.setEnabledModelIDs(resolved)
        }
    }

    @discardableResult
    public func selectAction(_ action: ActionConfig) -> Bool {
        guard selectedActionID != action.id else { return false }
        selectedActionID = action.id
        setResolvedTargetLanguage(nil, reason: "Selected action changed")
        setDetectedSourceLanguage(nil, reason: "Selected action changed")
        return true
    }

    public func performSelectedAction(
        refreshEntitlement: Bool = true,
        allowModelFallback: Bool = false
    ) {
        cancelActiveRequest(clearResults: false)
        if refreshEntitlement {
            currentRequestTask = Task { [weak self] in
                await Entitlement.shared.refresh()
                guard !Task.isCancelled else { return }
                // Already refreshed once; per-model requests reuse the cached result.
                self?.performSelectedActionWithCurrentEntitlement(
                    refreshEntitlement: false,
                    allowModelFallback: allowModelFallback
                )
            }
        } else {
            performSelectedActionWithCurrentEntitlement(
                refreshEntitlement: false,
                allowModelFallback: allowModelFallback
            )
        }
    }

    private func performSelectedActionWithCurrentEntitlement(
        refreshEntitlement: Bool,
        allowModelFallback: Bool
    ) {
        // Check data sharing consent before sending any data (macOS only).
        // Direct distribution bypasses this notice — Direct users explicitly opted into
        // a self-hosted/Developer-ID build and the cloud proxy is not the default path.
        #if os(macOS)
            if !BuildEnvironment.isDirectDistribution, !preferences.hasAcceptedDataSharing {
                showDataConsentRequest = true
                return
            }
        #endif

        guard var action = selectedAction else {
            logger.debug("No action selected.")
            modelRuns = []
            return
        }

        let rawText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty || !attachedImages.isEmpty else {
            logger.debug("Input text is empty and no images attached; skipping request.")
            modelRuns = []
            return
        }
        let text = action.category == .translation ? InputTextNormalizer.normalize(rawText) : rawText
        if action.id == BuiltInActionCatalog.translateActionID, WordLookupDetector.isWordOrPhrase(rawText) {
            action.prompt = BuiltInActionCatalog.wordLookupPrompt
        }

        currentRequestInputText = text
        currentRequestImages = attachedImages

        let cachedIsPremium = Entitlement.shared.isPro
        let modelsToUse = getEnabledModels(
            cachedIsPremium: cachedIsPremium,
            allowModelFallback: allowModelFallback
        )

        guard !modelsToUse.isEmpty else {
            if models.isEmpty, isLoadingModels {
                // Models still loading from network; queue for auto-trigger.
                logger.debug("Models not loaded yet; marking pending auto-action.")
                pendingAutoAction = true
                modelRuns = []
            } else {
                // Models loaded but none available — show error to user.
                logger
                    .debug(
                        "No usable models found. models=\(self.models.map(\.id), privacy: .public), enabledIDs=\(self.preferences.enabledModelIDs, privacy: .public)"
                    )
                let message = requiresAIModelSelection(for: action)
                    ? String(localized: "This action needs an AI model. Select one in Models.")
                    : "No models available. Please select a model in the Models tab."
                modelRuns = [
                    ModelRunViewState(
                        model: ModelConfig(id: "error", displayName: "Error"),
                        status: .failure(
                            message: message,
                            duration: 0
                        )
                    ),
                ]
            }
            return
        }

        // Clear pending flag since we're now executing
        pendingAutoAction = false

        // Clear throttle timestamps for this request
        lastStreamingUpdateTime.removeAll()

        setResolvedTargetLanguage(nil, reason: "Starting selected action request")
        setDetectedSourceLanguage(nil, reason: "Starting selected action request")

        let generation = UUID()
        let context = RequestContext(
            generation: generation,
            historyRequestID: generation,
            text: text,
            images: attachedImages,
            action: action,
            languages: consumeResolvedTarget(for: text),
            showsDiff: action.showsDiff,
            refreshEntitlement: refreshEntitlement,
            cachedIsPremium: cachedIsPremium
        )
        let runTokens = Dictionary(uniqueKeysWithValues: modelsToUse.map { ($0.id, UUID()) })
        activeRequestContext = context
        requestGenerationTracker.begin(generation: generation, runTokens: runTokens)

        modelRuns = modelsToUse.map {
            ModelRunViewState(model: $0, status: .running(start: Date()))
        }

        currentRequestTask = Task { [weak self] in
            await self?.executeRequest(
                context: context,
                models: modelsToUse,
                runTokens: runTokens,
                taskOwner: .primary
            )
        }
    }

    /// Retry a single model run (used by the per-result-card Retry button).
    /// This should NOT cancel or restart other model runs.
    public func retryRun(runID: String) {
        guard let context = activeRequestContext else { return }
        guard let index = modelRuns.firstIndex(where: { $0.id == runID }) else { return }

        guard !context.text.isEmpty || !context.images.isEmpty else { return }

        guard let runContext = requestContext(for: modelRuns[index].presentation, base: context) else { return }
        startSingleRun(at: index, context: runContext)
    }

    private var sentenceTranslateAction: ActionConfig? {
        let id = BuiltInActionCatalog.sentenceTranslateActionID
        return allActions.first { $0.id == id } ?? BuiltInActionCatalog.actions.first { $0.id == id }
    }

    /// Sentence pairs are offered on AI results of plain translation actions.
    public func canShowSentencePairs(for run: ModelRunViewState) -> Bool {
        guard let context = activeRequestContext,
              context.action.outputType == .translate,
              !run.model.isDirectTranslation,
              sentenceTranslateAction != nil
        else {
            return false
        }
        return true
    }

    /// Switches one run between the whole translation and sentence pairs. Only this run
    /// reloads (or restores its cached result); other runs are untouched.
    public func toggleSentencePairs(runID: String) {
        guard let context = activeRequestContext,
              let index = modelRuns.firstIndex(where: { $0.id == runID })
        else {
            return
        }

        let current = modelRuns[index]
        let next: ModelRunViewState.Presentation = current.presentation == .standard ? .sentencePairs : .standard
        if case .success = current.status {
            modelRuns[index].cachedStatuses[current.presentation] = current.status
        }
        modelRuns[index].presentation = next

        if let cached = modelRuns[index].cachedStatuses[next] {
            // Invalidate any in-flight run for this cell before restoring the cached result.
            perRunTasks[runID]?.cancel()
            requestGenerationTracker.retry(runID: runID, token: UUID())
            modelRuns[index].status = cached
            return
        }

        guard let runContext = requestContext(for: next, base: context) else { return }
        // Keep the original output time so the row does not jump in first-result order.
        startSingleRun(at: index, context: runContext, keepsResultOrder: true)
    }

    private func requestContext(
        for presentation: ModelRunViewState.Presentation,
        base context: RequestContext
    ) -> RequestContext? {
        switch presentation {
        case .standard:
            return context
        case .sentencePairs:
            guard let action = sentenceTranslateAction else { return nil }
            return context.withAction(action, historyRequestID: context.sentencePairsHistoryRequestID)
        }
    }

    private func startSingleRun(at index: Int, context: RequestContext, keepsResultOrder: Bool = false) {
        let runID = modelRuns[index].id
        let model = modelRuns[index].model

        // Cancel any in-flight retry for this run only
        perRunTasks[runID]?.cancel()

        let runToken = UUID()
        requestGenerationTracker.retry(runID: runID, token: runToken)

        // Reset UI state for this specific run
        modelRuns[index].markdownStreamSource.reset()
        modelRuns[index].status = .running(start: Date())
        if !keepsResultOrder {
            modelRuns[index].firstOutputAt = nil
        }

        perRunTasks[runID] = Task { [weak self] in
            await self?.executeRequest(
                context: context,
                models: [model],
                runTokens: [runID: runToken],
                taskOwner: .retry(runID: runID, runToken: runToken)
            )
        }
    }

    /// Present the debug request detail sheet for a specific model run.
    /// No-ops unless `DeveloperMode.isEnabled` — the sheet won't be bound
    /// in that case anyway, but we short-circuit to keep the file I/O off
    /// the hot path for non-developer users.
    public func presentDebugRequestDetails(for runID: String) {
        guard DeveloperMode.isEnabled else {
            selectedDebugNetworkRecord = nil
            return
        }
        // Pull latest cross-process logs (extension may have written to file)
        NetworkRequestLogger.shared.reloadFromFile()

        let path = "/\(runID)/chat/completions"

        // Best-effort match: choose the most recent request that hit this model route.
        if let record = NetworkRequestLogger.shared.records.first(where: { $0.urlPath == path }) {
            selectedDebugNetworkRecord = record
            return
        }

        // Fallback: contains match (handles query params / different host formatting)
        if let record = NetworkRequestLogger.shared.records.first(where: { $0.url.contains(path) }) {
            selectedDebugNetworkRecord = record
            return
        }

        selectedDebugNetworkRecord = nil
    }

    /// Manually override the target language for the next translation and re-execute.
    /// Used by the language switcher menu. Target is never automatically redirected,
    /// so `resolvedTargetLanguage` stays nil — the override is consumed once on the next request.
    public func overrideTargetLanguage(
        _ language: TargetLanguageOption,
        refreshEntitlement: Bool = true,
        allowModelFallback: Bool = false
    ) {
        setTargetLanguageOverride(language, reason: "Manual one-shot target override")
        setResolvedTargetLanguage(nil, reason: "Manual one-shot target override")
        performSelectedAction(
            refreshEntitlement: refreshEntitlement,
            allowModelFallback: allowModelFallback
        )
    }

    /// Called when the user picks a new source language — clears the detected source until the preview refreshes.
    public func clearDetectedSourceLanguage() {
        setDetectedSourceLanguage(nil, reason: "User changed source language")
    }

    public func swapInputLanguages() {
        let source = preferences.sourceLanguage
        let target = preferences.targetLanguage
        let matchCandidates = TargetLanguageOption.matchCandidates
        var concreteSource: SourceLanguageOption? = source == .auto ? detectedSourceLanguage : source
        if source == .auto,
           !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            _ = detectSourceCodeConstrained(for: inputText, candidateCodes: matchCandidates.map(\.rawValue))
            concreteSource = detectedSourceLanguage
        }
        let concreteTarget: TargetLanguageOption? = if target == .appLanguage {
            resolvedTargetLanguage ?? Self.resolveTargetLanguage(
                preferred: target,
                override: nil,
                sourceCode: concreteSource?.rawValue,
                matchCandidates: matchCandidates
            ).target
        } else {
            nil
        }
        let result = LanguageDirectionSwap.swapped(
            source: source,
            target: target,
            resolvedSource: concreteSource,
            resolvedTarget: concreteTarget
        )
        logger.notice(
            "Input keyboard swap requested source=\(source.rawValue, privacy: .public) target=\(target.rawValue, privacy: .public) resolvedSource=\(concreteSource?.rawValue ?? "nil", privacy: .public) resolvedTarget=\(concreteTarget?.rawValue ?? "nil", privacy: .public) nextSource=\(result.source.rawValue, privacy: .public) nextTarget=\(result.target.rawValue, privacy: .public)"
        )
        preferences.setSourceLanguage(result.source, reason: "Input keyboard swap")
        preferences.setTargetLanguage(result.target, reason: "Input keyboard swap")
        if result.source != source {
            clearDetectedSourceLanguage()
        }
        logger.notice(
            "Input keyboard swap completed source=\(self.preferences.sourceLanguage.rawValue, privacy: .public) target=\(self.preferences.targetLanguage.rawValue, privacy: .public)"
        )
    }

    private func setResolvedTargetLanguage(_ language: TargetLanguageOption?, reason: String) {
        guard resolvedTargetLanguage != language else { return }

        let oldValue = resolvedTargetLanguage?.rawValue
        resolvedTargetLanguage = language
        logLanguageChange(
            field: "resolvedTargetLanguage",
            from: oldValue,
            to: language?.rawValue,
            reason: reason
        )
    }

    private func setTargetLanguageOverride(_ language: TargetLanguageOption?, reason: String) {
        guard targetLanguageOverride != language else { return }

        let oldValue = targetLanguageOverride?.rawValue
        targetLanguageOverride = language
        logLanguageChange(
            field: "targetLanguageOverride",
            from: oldValue,
            to: language?.rawValue,
            reason: reason
        )
    }

    private func setDetectedSourceLanguage(_ language: SourceLanguageOption?, reason: String) {
        guard detectedSourceLanguage != language else { return }

        let oldValue = detectedSourceLanguage?.rawValue
        detectedSourceLanguage = language
        logLanguageChange(
            field: "detectedSourceLanguage",
            from: oldValue,
            to: language?.rawValue,
            reason: reason
        )
    }

    private func logLanguageChange(field: String, from oldValue: String?, to newValue: String?, reason: String) {
        let message = LanguageChangeLog.message(
            scope: "HomeViewModel",
            field: field,
            from: oldValue,
            to: newValue,
            reason: reason
        )
        logger.debug("\(message, privacy: .public)")
    }

    public func toggleDiffDisplay(for runID: String) {
        guard let index = modelRuns.firstIndex(where: { $0.id == runID }) else {
            return
        }
        modelRuns[index].showDiff.toggle()
    }

    public func hasDiff(for runID: String) -> Bool {
        guard let run = modelRuns.first(where: { $0.id == runID }) else {
            return false
        }
        switch run.status {
        case let .success(result):
            return result.diff != nil
        default:
            return false
        }
    }

    public func isDiffShown(for runID: String) -> Bool {
        guard let run = modelRuns.first(where: { $0.id == runID }) else {
            return false
        }
        return run.showDiff
    }

    public func openFeedbackEmail() {
        FeedbackMail.openFallback(FeedbackMail.makeDraft())
    }

    // MARK: - TTS Playback

    /// Speaks the result text for a specific run
    public func speakResult(_ text: String, runID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !speakingModels.contains(runID) else { return }

        speakingModels.insert(runID)

        Task { [weak self] in
            guard let self else { return }
            await self.ttsService.speak(text: trimmed, textID: runID)
            await MainActor.run { [weak self] in
                self?.speakingModels.remove(runID)
            }
        }
    }

    /// Speaks the current input text
    public func speakInputText() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isSpeakingInputText else { return }

        isSpeakingInputText = true

        Task { [weak self] in
            guard let self else { return }
            await self.ttsService.speak(text: trimmed, textID: "input")
            await MainActor.run { [weak self] in
                self?.isSpeakingInputText = false
            }
        }
    }

    /// Check if a specific run is currently being spoken
    public func isSpeaking(runID: String) -> Bool {
        speakingModels.contains(runID)
    }

    /// Stop any current TTS playback
    public func stopSpeaking() {
        ttsService.stopPlayback()
        speakingModels.removeAll()
        isSpeakingInputText = false
    }

    // MARK: - Continue Conversation

    /// Creates a ``ConversationSession`` from a completed model run,
    /// reconstructing the original prompt messages so the conversation
    /// starts with full context.
    public func createConversation(from run: ModelRunViewState) -> ConversationSession? {
        guard let action = selectedAction else { return nil }

        // Extract the assistant's response text from the success state
        let assistantText: String
        switch run.status {
        case let .success(result):
            assistantText = result.copyText
        default:
            return nil
        }

        // Reconstruct the original messages using the same logic as LLMService
        var chatMessages: [ChatMessage] = []

        let text = currentRequestInputText
        let prompt = activeRequestContext?.action.prompt ?? action.prompt

        if prompt.isEmpty {
            chatMessages.append(ChatMessage(role: "user", content: text, images: currentRequestImages))
        } else {
            // Target language is always the user preference (never auto-redirected).
            let resolvedTarget = resolvedTargetLanguage ?? preferences.targetLanguage
            let processedPrompt = PromptSubstitution.substitute(
                prompt: prompt,
                text: text,
                targetLanguage: resolvedTarget.promptDescriptor,
                sourceLanguage: detectedSourceLanguage?.promptDescriptor ?? ""
            )
            let promptContainsTextPlaceholder = PromptSubstitution.containsTextPlaceholder(prompt)

            if promptContainsTextPlaceholder {
                chatMessages.append(ChatMessage(role: "user", content: processedPrompt, images: currentRequestImages))
            } else {
                chatMessages.append(ChatMessage(role: "system", content: processedPrompt))
                chatMessages.append(ChatMessage(role: "user", content: text, images: currentRequestImages))
            }
        }

        // Add the assistant's response
        chatMessages.append(ChatMessage(role: "assistant", content: assistantText))

        return ConversationSession(
            model: run.model,
            action: action,
            availableModels: conversationModels,
            messages: chatMessages
        )
    }

    /// Creates a conversation from a completed run with a pre-filled follow-up message.
    /// Used when the user taps a suggested action chip.
    public func createConversationWithFollowUp(from run: ModelRunViewState, followUp: String) -> ConversationSession? {
        guard var session = createConversation(from: run) else { return nil }
        session.pendingInput = followUp
        return session
    }

    /// Creates a conversation session with the selected text as context,
    /// without any prior translation results. Used by the extension's Chat button.
    public func createContextConversation(contextText: String) -> ConversationSession? {
        let availableModels = getEnabledModels()
        guard let model = availableModels.first,
              let action = selectedAction else { return nil }

        let trimmed = contextText.trimmingCharacters(in: .whitespacesAndNewlines)

        var chatMessages: [ChatMessage] = []
        if !trimmed.isEmpty {
            chatMessages.append(ChatMessage(
                role: "system",
                content: "The user has selected the following text. Use it as context for the conversation:\n\n\(trimmed)"
            ))
        }

        return ConversationSession(
            model: model,
            action: action,
            availableModels: conversationModels,
            messages: chatMessages
        )
    }

    deinit {
        currentRequestTask?.cancel()
        perRunTasks.values.forEach { $0.cancel() }
    }

    /// Result of `consumeResolvedTarget`: the resolved target language and
    /// the detected/pinned source language code (for reuse by Apple/Microsoft/LLM engines).
    struct ResolvedLanguagePair {
        let target: TargetLanguageOption
        /// BCP 47 source code (e.g. "en", "zh-Hans"), or nil when detection failed.
        let sourceCode: String?

        var targetLanguageDescriptor: String { target.promptDescriptor }

        /// Human-readable source descriptor for LLM prompts, e.g. "日本語 (Japanese)".
        /// Empty when source is unknown (auto-detect failed).
        var sourceLanguageDescriptor: String {
            guard let code = sourceCode else { return "" }
            let option = SourceLanguageOption(rawValue: code)
                ?? SourceLanguageOption(rawValue: String(code.prefix(2)))
            return option?.promptDescriptor ?? ""
        }
    }

    struct TargetLanguageResolution {
        let target: TargetLanguageOption
        let displayTarget: TargetLanguageOption?
    }

    nonisolated static func resolveTargetLanguage(
        preferred: TargetLanguageOption,
        override: TargetLanguageOption?,
        sourceCode: String?,
        matchCandidates: [TargetLanguageOption] = TargetLanguageOption.matchCandidates
    ) -> TargetLanguageResolution {
        if let override, override != .appLanguage {
            return TargetLanguageResolution(
                target: override,
                displayTarget: override == preferred ? nil : override
            )
        }

        if preferred == .appLanguage || override == .appLanguage {
            let resolved = SourceLanguageDetector.resolveMatchTarget(sourceCode: sourceCode, candidates: matchCandidates)
            return TargetLanguageResolution(target: resolved, displayTarget: resolved)
        }

        return TargetLanguageResolution(target: preferred, displayTarget: nil)
    }

    /// Consumes `targetLanguageOverride` if set, otherwise returns the user's preferred target.
    /// Manual target languages are never automatically redirected. Only Match resolves
    /// to a concrete target based on the detected source language.
    /// Source language detection biases away from the target so mixed-language input
    /// (e.g. "你好, hello") picks the *other* language when the user is in `.auto` mode.
    private func consumeResolvedTarget(for text: String) -> ResolvedLanguagePair {
        let preferredTarget = preferences.targetLanguage
        let overrideTarget = targetLanguageOverride
        if overrideTarget != nil {
            setTargetLanguageOverride(nil, reason: "Consumed one-shot target override")
        }
        languagePreviewTask?.cancel()
        let resolution = Self.resolveLanguages(
            text: text,
            sourcePreference: preferences.sourceLanguage,
            preferredTarget: preferredTarget,
            override: overrideTarget
        )
        applyLanguageResolution(resolution, reason: "Request")
        return ResolvedLanguagePair(target: resolution.target, sourceCode: resolution.sourceCode)
    }

    struct LanguageResolution: Equatable {
        /// BCP 47 source code used for the request, or nil when detection is inconclusive.
        let sourceCode: String?
        /// Source shown in the UI: the detected language, or the pinned preference.
        let displaySource: SourceLanguageOption?
        let target: TargetLanguageOption
        let displayTarget: TargetLanguageOption?
        let isMatchFallback: Bool
    }

    /// Resolves the language pair for `text` without touching view-model state, so the live
    /// preview while typing and the actual request always agree.
    /// Detection biases away from the target so mixed-language input (e.g. "你好, hello")
    /// picks the *other* language when the source is `.auto`.
    nonisolated static func resolveLanguages(
        text: String,
        sourcePreference: SourceLanguageOption,
        preferredTarget: TargetLanguageOption,
        override: TargetLanguageOption?,
        matchCandidates: [TargetLanguageOption] = TargetLanguageOption.matchCandidates
    ) -> LanguageResolution {
        let resolvesMatch = override == .appLanguage || (override == nil && preferredTarget == .appLanguage)

        let sourceCode: String?
        if sourcePreference != .auto {
            sourceCode = sourcePreference.rawValue
        } else if resolvesMatch {
            sourceCode = SourceLanguageDetector.detectLocaleLanguageConstrained(
                of: text,
                candidateCodes: matchCandidates.map(\.rawValue)
            )?.minimalIdentifier
        } else {
            let target = override ?? preferredTarget
            sourceCode = SourceLanguageDetector.detectLocaleLanguage(
                of: text,
                excludingTargetCode: target.rawValue
            )?.minimalIdentifier
        }

        let displaySource: SourceLanguageOption? = if sourcePreference != .auto {
            sourcePreference
        } else {
            // Detection returns minimal codes ("zh" for zh-Hans), so match by language equivalence.
            sourceCode.flatMap { code in
                SourceLanguageOption(rawValue: code) ?? SourceLanguageOption.allCases.first {
                    $0 != .auto && SourceLanguageDetector.languagesAreSame($0.rawValue, code)
                }
            }
        }

        let resolved = resolveTargetLanguage(
            preferred: preferredTarget,
            override: override,
            sourceCode: sourceCode,
            matchCandidates: matchCandidates
        )
        let isMatchFallback = resolvesMatch && sourceCode != nil && resolved.target != matchCandidates.first

        return LanguageResolution(
            sourceCode: sourceCode,
            displaySource: displaySource,
            target: resolved.target,
            displayTarget: resolved.displayTarget,
            isMatchFallback: isMatchFallback
        )
    }

    private func applyLanguageResolution(_ resolution: LanguageResolution?, reason: String) {
        setDetectedSourceLanguage(resolution?.displaySource, reason: "\(reason): source=\(resolution?.sourceCode ?? "nil")")
        setResolvedTargetLanguage(resolution?.displayTarget, reason: "\(reason): target resolved")
        if isMatchTargetFallback != (resolution?.isMatchFallback ?? false) {
            isMatchTargetFallback = resolution?.isMatchFallback ?? false
        }
    }

    /// Debounced so language detection runs once the user pauses typing.
    private func scheduleLanguagePreviewRefresh() {
        languagePreviewTask?.cancel()
        languagePreviewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshLanguagePreview()
        }
    }

    private func refreshLanguagePreview() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            applyLanguageResolution(nil, reason: "Live preview cleared")
            return
        }
        applyLanguageResolution(
            Self.resolveLanguages(
                text: text,
                sourcePreference: preferences.sourceLanguage,
                preferredTarget: preferences.targetLanguage,
                override: targetLanguageOverride
            ),
            reason: "Live preview"
        )
    }

    /// Match mode: detects source language constrained to candidate language codes only.
    private func detectSourceCodeConstrained(for text: String, candidateCodes: [String]) -> String? {
        let sourceLanguage = preferences.sourceLanguage
        if sourceLanguage != .auto {
            setDetectedSourceLanguage(sourceLanguage, reason: "Source language preference is pinned")
            return sourceLanguage.rawValue
        }
        guard let detected = SourceLanguageDetector.detectLocaleLanguageConstrained(of: text, candidateCodes: candidateCodes)
        else {
            return nil
        }
        let code = detected.minimalIdentifier
        let detectedOption = SourceLanguageOption(rawValue: code)
            ?? SourceLanguageOption(rawValue: String(code.prefix(2)))
        setDetectedSourceLanguage(
            detectedOption,
            reason: "Auto source detected within candidates=\(candidateCodes.joined(separator: ","))"
        )
        return code
    }

    /// If user chose source==target (or auto-detected source matches target), Apple Translate
    /// physically can't translate — return a localized error result instead of calling the API.
    private func sameSourceAndTargetResult(
        sourceCode: String?,
        target: TargetLanguageOption,
        modelID: String = ModelConfig.appleTranslateID
    ) -> ModelExecutionResult? {
        let targetCode = target == .appLanguage ? TargetLanguageOption.appLanguageIdentifier : target.rawValue
        guard let sourceCode,
              SourceLanguageDetector.languagesAreSame(sourceCode, targetCode)
        else {
            return nil
        }
        logger.error("\(modelID, privacy: .public): source==target (\(sourceCode, privacy: .public)), short-circuiting")
        return ModelExecutionResult(
            modelID: modelID,
            duration: 0,
            response: .failure(LocalProviderError.sameSourceAndTarget(
                language: target.englishName,
                languagePair: AppleTranslationErrorFormatter.languagePairDescription(sourceCode: sourceCode, target: target)
            ))
        )
    }

    private func isRunStillValid(_ context: RequestContext, runID: String, runToken: UUID) -> Bool {
        requestGenerationTracker.accepts(
            generation: context.generation,
            runID: runID,
            token: runToken
        )
    }

    private func executeRequest(
        context: RequestContext,
        models: [ModelConfig],
        runTokens: [String: UUID],
        taskOwner: RequestTaskOwner
    ) async {
        defer {
            finishRequestTask(taskOwner, context: context)
        }
        guard !Task.isCancelled else { return }

        let text = context.text
        let action = context.action
        let resolved = context.languages
        let resolvedTarget = resolved.target

        // Separate direct translation services from cloud LLM models.
        let cloudModels = models.filter { !$0.isDirectTranslation }
        let hasAppleTranslate = models.contains { $0.id == ModelConfig.appleTranslateID }
        logger
            .debug(
                "executeRequest: \(models.count, privacy: .public) models, apple=\(hasAppleTranslate, privacy: .public)"
            )

        // Kick off Apple Translate if present.
        if hasAppleTranslate {
            guard let appleRunToken = runTokens[ModelConfig.appleTranslateID] else { return }
            if action.supportsAppleTranslate {
                if supportsAppleTranslate {
                    // SwiftUI context: prefer the direct TranslationSession(installedSource:target:)
                    // path when the language pack is already installed; fall back to .translationTask()
                    // only when a download is required.
                    let sourceLocale: Locale.Language? = resolved.sourceCode.map { Locale.Language(identifier: $0) }
                    let targetLocale = resolvedTarget.localeLanguage
                    if let shortCircuit = sameSourceAndTargetResult(sourceCode: resolved.sourceCode, target: resolvedTarget) {
                        apply(result: shortCircuit, context: context, runToken: appleRunToken, allowDiff: false)
                    } else {
                        Task { [weak self] in
                            guard let self else { return }
                            if #available(iOS 17.4, macOS 14.4, *) {
                                do {
                                    let status = try await AppleTranslationService.shared.languageAvailabilityStatus(
                                        source: sourceLocale, target: targetLocale
                                    )
                                    guard !Task.isCancelled,
                                          self.isRunStillValid(
                                              context,
                                              runID: ModelConfig.appleTranslateID,
                                              runToken: appleRunToken
                                          )
                                    else {
                                        return
                                    }
                                    if status == .installed {
                                        // Language pack already on device — skip SwiftUI bridge entirely.
                                        let result: ModelExecutionResult
                                        if action.outputType == .sentencePairs {
                                            result = try await AppleTranslationService.shared
                                                .translateSentencesWithInstalledLanguages(
                                                    text: text,
                                                    source: sourceLocale,
                                                    target: targetLocale
                                                )
                                        } else {
                                            result = try await AppleTranslationService.shared.translateWithInstalledLanguages(
                                                text: text, source: sourceLocale, target: targetLocale
                                            )
                                        }
                                        guard self.isRunStillValid(
                                            context,
                                            runID: result.modelID,
                                            runToken: appleRunToken
                                        ) else { return }
                                        self.apply(
                                            result: result,
                                            context: context,
                                            runToken: appleRunToken,
                                            allowDiff: false
                                        )
                                        self.saveHistoryIfSuccessful(
                                            result,
                                            context: context,
                                            runToken: appleRunToken
                                        )
                                    } else {
                                        // Language pack not installed; need .translationTask() to trigger download UI.
                                        self.pendingAppleTranslateText = text
                                        self.pendingAppleTranslateAction = action
                                        self.pendingAppleTranslateRequestID = context.historyRequestID
                                        self.pendingAppleTranslateResolvedTarget = resolvedTarget
                                        self.pendingAppleTranslateContext = context
                                        self.pendingAppleTranslateRunToken = appleRunToken
                                        self.appleTranslateSourceLanguage = sourceLocale
                                        self.appleTranslateTargetLanguage = resolvedTarget
                                        logger
                                            .debug(
                                                "Apple Translate: published target=\(resolvedTarget.englishName, privacy: .public), starting \(AppleTranslationService.operationTimeoutSeconds, privacy: .public)s timeout watchdog"
                                            )
                                        self.appleTranslationRequestHandler?(sourceLocale, resolvedTarget)

                                        try? await Task.sleep(for: .seconds(AppleTranslationService.operationTimeoutSeconds))
                                        guard !Task.isCancelled,
                                              self.pendingAppleTranslateContext?.generation == context.generation,
                                              self.pendingAppleTranslateRunToken == appleRunToken
                                        else { return }
                                        logger
                                            .error(
                                                "Apple Translate watchdog fired — .translationTask() did not respond in \(AppleTranslationService.operationTimeoutSeconds, privacy: .public)s, source=\(sourceLocale?.minimalIdentifier ?? "auto", privacy: .public), target=\(resolvedTarget.rawValue, privacy: .public), status=\(String(describing: status), privacy: .public)"
                                            )
                                        self.pendingAppleTranslateText = nil
                                        self.pendingAppleTranslateAction = nil
                                        self.pendingAppleTranslateRequestID = nil
                                        self.pendingAppleTranslateResolvedTarget = nil
                                        self.pendingAppleTranslateContext = nil
                                        self.pendingAppleTranslateRunToken = nil
                                        self.appleTranslateSourceLanguage = nil
                                        self.appleTranslateTargetLanguage = nil
                                        guard self.isRunStillValid(
                                            context,
                                            runID: ModelConfig.appleTranslateID,
                                            runToken: appleRunToken
                                        ) else { return }
                                        let timeoutResult = ModelExecutionResult(
                                            modelID: ModelConfig.appleTranslateID,
                                            duration: TimeInterval(AppleTranslationService.operationTimeoutSeconds),
                                            response: .failure(
                                                LocalProviderError
                                                    .translationFailed(
                                                        AppleTranslationErrorFormatter.withLanguagePair(
                                                            "Apple Translate timed out after \(AppleTranslationService.operationTimeoutSeconds) seconds. Language pack may not be available.",
                                                            source: sourceLocale,
                                                            target: resolvedTarget
                                                        )
                                                    )
                                            )
                                        )
                                        self.apply(
                                            result: timeoutResult,
                                            context: context,
                                            runToken: appleRunToken,
                                            allowDiff: false
                                        )
                                    }
                                } catch {
                                    logger
                                        .error(
                                            "Apple Translate failed: \(String(describing: error), privacy: .public), source=\(sourceLocale?.minimalIdentifier ?? "auto", privacy: .public), target=\(targetLocale.minimalIdentifier, privacy: .public)"
                                        )
                                    guard self.isRunStillValid(
                                        context,
                                        runID: ModelConfig.appleTranslateID,
                                        runToken: appleRunToken
                                    ) else { return }
                                    let fail = ModelExecutionResult(
                                        modelID: ModelConfig.appleTranslateID,
                                        duration: 0,
                                        response: .failure(
                                            LocalProviderError
                                                .translationFailed(AppleTranslationErrorFormatter.describe(
                                                    error,
                                                    source: sourceLocale,
                                                    target: resolvedTarget
                                                ))
                                        )
                                    )
                                    self.apply(
                                        result: fail,
                                        context: context,
                                        runToken: appleRunToken,
                                        allowDiff: false
                                    )
                                }
                            }
                        }
                    }
                } else {
                    // Non-SwiftUI context (e.g. extension): use TranslationSession(installedSource:target:)
                    // directly. Only works if language packs are already installed.
                    let sourceLocale: Locale.Language? = resolved.sourceCode.map { Locale.Language(identifier: $0) }
                    let targetLocale = resolvedTarget.localeLanguage
                    if let shortCircuit = sameSourceAndTargetResult(sourceCode: resolved.sourceCode, target: resolvedTarget) {
                        apply(result: shortCircuit, context: context, runToken: appleRunToken, allowDiff: false)
                    } else {
                        Task { [weak self] in
                            guard let self else { return }
                            // Always true at runtime (guarded by isAvailable in getEnabledModels),
                            // but required for the compiler's availability check.
                            if #available(iOS 17.4, macOS 14.4, *) {
                                do {
                                    let result: ModelExecutionResult
                                    if action.outputType == .sentencePairs {
                                        result = try await AppleTranslationService.shared
                                            .translateSentencesWithInstalledLanguages(
                                                text: text,
                                                source: sourceLocale,
                                                target: targetLocale
                                            )
                                    } else {
                                        result = try await AppleTranslationService.shared.translateWithInstalledLanguages(
                                            text: text, source: sourceLocale, target: targetLocale
                                        )
                                    }
                                    guard self.isRunStillValid(
                                        context,
                                        runID: result.modelID,
                                        runToken: appleRunToken
                                    ) else { return }
                                    self.apply(
                                        result: result,
                                        context: context,
                                        runToken: appleRunToken,
                                        allowDiff: false
                                    )
                                    self.saveHistoryIfSuccessful(
                                        result,
                                        context: context,
                                        runToken: appleRunToken
                                    )
                                } catch {
                                    logger
                                        .error(
                                            "Apple Translate (non-SwiftUI path) failed: \(String(describing: error), privacy: .public), source=\(sourceLocale?.minimalIdentifier ?? "auto", privacy: .public), target=\(targetLocale.minimalIdentifier, privacy: .public)"
                                        )
                                    guard self.isRunStillValid(
                                        context,
                                        runID: ModelConfig.appleTranslateID,
                                        runToken: appleRunToken
                                    ) else { return }
                                    let fail = ModelExecutionResult(
                                        modelID: ModelConfig.appleTranslateID,
                                        duration: 0,
                                        response: .failure(
                                            LocalProviderError
                                                .translationFailed(AppleTranslationErrorFormatter.describe(
                                                    error,
                                                    source: sourceLocale,
                                                    target: resolvedTarget
                                                ))
                                        )
                                    )
                                    self.apply(
                                        result: fail,
                                        context: context,
                                        runToken: appleRunToken,
                                        allowDiff: false
                                    )
                                }
                            }
                        }
                    }
                }
            } else {
                // Unsupported action — show inline error immediately.
                logger.error("Apple Translate: action '\(action.name, privacy: .public)' does not support Apple Translate")
                let result = ModelExecutionResult(
                    modelID: ModelConfig.appleTranslateID,
                    duration: 0,
                    response: .failure(LocalProviderError.unsupportedAction)
                )
                apply(result: result, context: context, runToken: appleRunToken, allowDiff: false)
            }
        }

        for model in models where model.id == ModelConfig.microsoftTranslateID {
            guard let serviceRunToken = runTokens[model.id] else { continue }
            if action.supportsAppleTranslate {
                if let shortCircuit = sameSourceAndTargetResult(
                    sourceCode: resolved.sourceCode,
                    target: resolvedTarget,
                    modelID: model.id
                ) {
                    apply(result: shortCircuit, context: context, runToken: serviceRunToken, allowDiff: false)
                } else {
                    let sourceCode: String? = resolved.sourceCode
                    Task { [weak self] in
                        guard let self else { return }
                        let result = await MicrosoftTranslateService.shared.translate(
                            text: text, sourceCode: sourceCode, targetCode: resolvedTarget.rawValue
                        )
                        guard self.isRunStillValid(
                            context,
                            runID: result.modelID,
                            runToken: serviceRunToken
                        ) else { return }
                        self.apply(
                            result: result,
                            context: context,
                            runToken: serviceRunToken,
                            allowDiff: false
                        )
                        self.saveHistoryIfSuccessful(
                            result,
                            context: context,
                            runToken: serviceRunToken
                        )
                    }
                }
            } else {
                let result = ModelExecutionResult(
                    modelID: model.id,
                    duration: 0,
                    response: .failure(LocalProviderError.unsupportedAction)
                )
                apply(result: result, context: context, runToken: serviceRunToken, allowDiff: false)
            }
        }

        // Run cloud models through the existing LLM path.
        guard !cloudModels.isEmpty else {
            return
        }

        let results = await llmService.perform(
            text: text,
            with: action,
            models: cloudModels,
            images: context.images,
            targetLanguageDescriptor: resolved.targetLanguageDescriptor,
            sourceLanguageDescriptor: resolved.sourceLanguageDescriptor,
            onboardingTrial: !onboardingTrialModels.isEmpty,
            refreshEntitlement: context.refreshEntitlement,
            cachedIsPremium: context.cachedIsPremium,
            partialHandler: { [weak self] modelID, update in
                guard let self else { return }
                guard let runToken = runTokens[modelID],
                      self.isRunStillValid(context, runID: modelID, runToken: runToken)
                else { return }
                guard let index = self.modelRuns.firstIndex(where: { $0.id == modelID }) else {
                    return
                }

                // Throttle streaming UI updates to ~15Hz (66ms)
                let now = Date()
                if let lastUpdate = self.lastStreamingUpdateTime[modelID],
                   now.timeIntervalSince(lastUpdate) < 0.066
                {
                    return
                }
                self.lastStreamingUpdateTime[modelID] = now

                let startDate = self.modelRuns[index].startDate ?? Date()
                switch update {
                case let .text(partialText):
                    if !partialText.isEmpty, self.modelRuns[index].firstOutputAt == nil {
                        self.modelRuns[index].firstOutputAt = now
                    }
                    self.modelRuns[index].markdownStreamSource.yield(partialText)
                    self.modelRuns[index].status = .streaming(
                        text: partialText,
                        start: startDate
                    )
                case let .sentencePairs(pairs):
                    if !pairs.isEmpty, self.modelRuns[index].firstOutputAt == nil {
                        self.modelRuns[index].firstOutputAt = now
                    }
                    self.modelRuns[index].status = .streamingSentencePairs(
                        pairs: pairs,
                        start: startDate
                    )
                }
            },
            completionHandler: { [weak self] result in
                guard let self else { return }
                guard let runToken = runTokens[result.modelID],
                      self.isRunStillValid(context, runID: result.modelID, runToken: runToken)
                else { return }
                self.modelRuns.first { $0.id == result.modelID }?.markdownStreamSource.finish()
                self.apply(
                    result: result,
                    context: context,
                    runToken: runToken,
                    allowDiff: context.showsDiff
                )
                self.saveHistoryIfSuccessful(result, context: context, runToken: runToken)
            }
        )

        guard !Task.isCancelled else { return }
        let validResults = results.filter { result in
            guard let runToken = runTokens[result.modelID] else { return false }
            return isRunStillValid(context, runID: result.modelID, runToken: runToken)
        }
        guard !validResults.isEmpty else { return }

        let hasSuccess = validResults.contains { result in
            if case .success = result.response { return true }
            return false
        }
        if hasSuccess {
            successfulTranslationCount += 1
            if preferences.shouldShowSatisfactionPrompt {
                showSatisfactionPrompt = true
            }
        }
    }

    private var conversationModels: [ModelConfig] {
        ModelConfig.appleIntelligenceModels.filter {
            FoundationModelService.availability(for: $0).isAvailable
        } + models
    }

    private func finishRequestTask(_ owner: RequestTaskOwner, context: RequestContext) {
        let generationMatches = activeRequestContext?.generation == context.generation
        let retryMatches: Bool
        if case let .retry(runID, runToken) = owner {
            retryMatches = requestGenerationTracker.accepts(
                generation: context.generation,
                runID: runID,
                token: runToken
            )
        } else {
            retryMatches = false
        }

        switch Self.taskCleanup(
            for: owner,
            generationMatches: generationMatches,
            retryMatches: retryMatches
        ) {
        case .none:
            break
        case .primary:
            currentRequestTask = nil
        case let .retry(runID):
            perRunTasks[runID] = nil
        }
    }

    private func cancelActiveRequest(clearResults: Bool) {
        currentRequestTask?.cancel()
        currentRequestTask = nil
        for task in perRunTasks.values {
            task.cancel()
        }
        perRunTasks.removeAll()
        activeRequestContext = nil
        requestGenerationTracker.cancel()
        pendingAppleTranslateText = nil
        pendingAppleTranslateAction = nil
        pendingAppleTranslateRequestID = nil
        pendingAppleTranslateResolvedTarget = nil
        pendingAppleTranslateContext = nil
        pendingAppleTranslateRunToken = nil
        appleTranslateSourceLanguage = nil
        appleTranslateTargetLanguage = nil
        setDetectedSourceLanguage(nil, reason: "Active request cancelled")
        if clearResults {
            if !modelRuns.isEmpty { modelRuns = [] }
            setTargetLanguageOverride(nil, reason: "Active request cancelled and results cleared")
        }
    }

    // MARK: - Apple Translation Execution

    /// Called from HomeView's `.translationTask()` callback once a TranslationSession is available.
    #if canImport(Translation)
        @available(iOS 17.4, macOS 14.4, *)
        public func executeAppleTranslation(session: TranslationSession) async {
            logger
                .debug(
                    "executeAppleTranslation: hasText=\(self.pendingAppleTranslateText != nil, privacy: .public), hasAction=\(self.pendingAppleTranslateAction != nil, privacy: .public)"
                )
            guard let text = pendingAppleTranslateText,
                  let action = pendingAppleTranslateAction,
                  let context = pendingAppleTranslateContext,
                  let runToken = pendingAppleTranslateRunToken
            else {
                logger
                    .error(
                        "executeAppleTranslation: missing pending state, aborting (text=\(self.pendingAppleTranslateText != nil, privacy: .public), action=\(self.pendingAppleTranslateAction != nil, privacy: .public), requestID=\(self.pendingAppleTranslateRequestID != nil, privacy: .public))"
                    )
                return
            }

            // Clear pending state.
            let resolvedTarget = pendingAppleTranslateResolvedTarget ?? preferences.targetLanguage
            let sourceLocale = appleTranslateSourceLanguage
            pendingAppleTranslateText = nil
            pendingAppleTranslateAction = nil
            pendingAppleTranslateRequestID = nil
            pendingAppleTranslateResolvedTarget = nil
            pendingAppleTranslateContext = nil
            pendingAppleTranslateRunToken = nil
            appleTranslateSourceLanguage = nil
            appleTranslateTargetLanguage = nil

            // The session is only valid inside the `.translationTask` closure, so run inline.
            do {
                let result: ModelExecutionResult
                if action.outputType == .sentencePairs {
                    result = try await AppleTranslationService.shared.translateSentences(
                        text: text, using: session
                    )
                } else {
                    result = try await AppleTranslationService.shared.translate(
                        text: text, using: session
                    )
                }
                guard isRunStillValid(
                    context,
                    runID: result.modelID,
                    runToken: runToken
                ) else { return }
                apply(result: result, context: context, runToken: runToken, allowDiff: false)
                saveHistoryIfSuccessful(result, context: context, runToken: runToken)
            } catch {
                logger.error("executeAppleTranslation failed: \(String(describing: error), privacy: .public)")
                guard isRunStillValid(
                    context,
                    runID: ModelConfig.appleTranslateID,
                    runToken: runToken
                ) else { return }
                let failResult = ModelExecutionResult(
                    modelID: ModelConfig.appleTranslateID,
                    duration: 0,
                    response: .failure(LocalProviderError.translationFailed(AppleTranslationErrorFormatter.describe(
                        error,
                        source: sourceLocale,
                        target: resolvedTarget
                    )))
                )
                apply(result: failResult, context: context, runToken: runToken, allowDiff: false)
            }
        }
    #endif

    private func saveHistoryIfSuccessful(
        _ result: ModelExecutionResult,
        context: RequestContext,
        runToken: UUID
    ) {
        guard onboardingTrialModels.isEmpty,
              isRunStillValid(context, runID: result.modelID, runToken: runToken),
              case let .success(message) = result.response,
              let run = modelRuns.first(where: { $0.id == result.modelID })
        else {
            return
        }

        TranslationHistoryService.shared.save(
            requestID: context.historyRequestID,
            sourceText: context.text,
            resultText: message,
            actionName: context.action.name,
            targetLanguage: context.languages.target.englishName,
            modelID: result.modelID,
            modelDisplayName: run.modelDisplayName,
            duration: result.duration
        )
    }

    private func apply(
        result: ModelExecutionResult,
        context: RequestContext,
        runToken: UUID,
        allowDiff: Bool
    ) {
        guard isRunStillValid(context, runID: result.modelID, runToken: runToken) else {
            return
        }
        guard let index = modelRuns.firstIndex(where: { $0.id == result.modelID }) else {
            return
        }

        let latencyBreakdown: ModelRunViewState.LatencyBreakdown?
        if let upstream = result.upstreamTTFB, let clientAzure = result.clientToAzureLatency {
            latencyBreakdown = .init(upstreamTTFB: upstream, clientToAzure: clientAzure, networkMetrics: result.networkMetrics)
        } else {
            latencyBreakdown = nil
        }

        switch result.response {
        case let .success(message):
            if modelRuns[index].firstOutputAt == nil {
                modelRuns[index].firstOutputAt = Date()
            }
            let diffTarget = result.diffSource ?? message
            if allowDiff {
                Task {
                    let diff = await Task.detached(priority: .userInitiated) {
                        TextDiffBuilder.build(original: context.text, revised: diffTarget)
                    }.value
                    guard self.isRunStillValid(
                        context,
                        runID: result.modelID,
                        runToken: runToken
                    ), let currentIndex = self.modelRuns.firstIndex(where: { $0.id == result.modelID })
                    else { return }
                    self.modelRuns[currentIndex].status = .success(ModelRunViewState.SuccessResult(
                        text: message,
                        copyText: diffTarget,
                        duration: result.duration,
                        diff: diff,
                        supplementalTexts: result.supplementalTexts,
                        sentencePairs: result.sentencePairs,
                        latencyBreakdown: latencyBreakdown,
                        suggestedActions: result.suggestedActions
                    ))
                }
            } else {
                modelRuns[index].status = .success(ModelRunViewState.SuccessResult(
                    text: message,
                    copyText: diffTarget,
                    duration: result.duration,
                    diff: nil,
                    supplementalTexts: result.supplementalTexts,
                    sentencePairs: result.sentencePairs,
                    latencyBreakdown: latencyBreakdown,
                    suggestedActions: result.suggestedActions
                ))
            }

        case let .failure(error):
            let responseBody: String?
            if let llmError = error as? LLMServiceError,
               case let .httpError(_, body) = llmError
            {
                responseBody = body
            } else {
                responseBody = nil
            }
            modelRuns[index].status = .failure(
                message: error.localizedDescription,
                duration: result.duration,
                responseBody: responseBody
            )
            let failedRun = modelRuns.remove(at: index)
            modelRuns.append(failedRun)
        }
    }

    private func refreshActions() {
        actions = allActions
        logger.debug("refreshActions() — \(self.allActions.count, privacy: .public) total")

        guard !allActions.isEmpty else {
            selectedActionID = nil
            return
        }

        if let selectedID = selectedActionID,
           allActions.contains(where: { $0.id == selectedID })
        {
            return
        }

        selectedActionID = allActions.first?.id
    }
}
