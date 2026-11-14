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
import Translation

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "HomeViewModel")
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
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
            public let providerDisplayName: String?

            public init(
                text: String,
                copyText: String,
                duration: TimeInterval,
                diff: TextDiffBuilder.Presentation? = nil,
                supplementalTexts: [String] = [],
                sentencePairs: [SentencePair] = [],
                latencyBreakdown: LatencyBreakdown? = nil,
                suggestedActions: [String] = [],
                providerDisplayName: String? = nil
            ) {
                self.text = text
                self.copyText = copyText
                self.duration = duration
                self.diff = diff
                self.supplementalTexts = supplementalTexts
                self.sentencePairs = sentencePairs
                self.latencyBreakdown = latencyBreakdown
                self.suggestedActions = suggestedActions
                self.providerDisplayName = providerDisplayName
            }
        }

        public enum Status {
            case idle
            case running(start: Date)
            case streaming(text: String, start: Date)
            case streamingSentencePairs(pairs: [SentencePair], start: Date)
            case success(SuccessResult)
            case failure(message: String, duration: TimeInterval, responseBody: String? = nil, isUnsupported: Bool = false)

            public var duration: TimeInterval? {
                switch self {
                case .idle, .running, .streaming, .streamingSentencePairs:
                    return nil
                case let .success(result):
                    return result.duration
                case let .failure(_, duration, _, _):
                    return duration
                }
            }

            /// The provider cannot handle the selected languages, so retrying would not help.
            public var isUnsupported: Bool {
                if case let .failure(_, _, _, isUnsupported) = self {
                    isUnsupported
                } else {
                    false
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
            /// Worker to upstream response headers, not the first content token.
            public let upstreamTTFB: TimeInterval
            /// Client header wait excluding upstream header wait; includes Worker overhead.
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
        public var timingTrace: TranslationTimingTrace?
        public var status: Status
        public var presentation: Presentation = .standard
        /// Finished status per presentation, so switching back never re-requests.
        var cachedStatuses: [Presentation: Status] = [:]
        /// Travels with copied results when another window adopts a snapshot.
        var requestLanguages: ResolvedLanguagePair?
        public var showDiff: Bool = true
        /// When this run first showed output; fixes its slot in first-result order.
        public var firstOutputAt: Date?

        public var id: String {
            model.id
        }

        public var modelDisplayName: String {
            if case let .success(result) = status, let name = result.providerDisplayName {
                return name
            }
            return model.displayName
        }

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
            if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sourceLanguageOverride = nil
                currentTextTarget = nil
            }
            // Keep the one-shot target and detected source while typing; the
            // debounced preview re-resolves them for the new text.
            cancelActiveRequest(clearResults: true, resetsLanguages: false)
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

    @Published public internal(set) var actions: [ActionConfig]
    @Published public internal(set) var models: [ModelConfig] = []
    @Published public internal(set) var isLoadingModels = false
    /// Cached catalogs can be stale, so enabled model IDs are reconciled only against a server response.
    var hasFetchedModels = false
    @Published public var selectedActionID: ActionConfig.ID?
    @Published public internal(set) var modelRuns: [ModelRunViewState] = []

    public var isWordLookupFallback: Bool {
        activeRequestContext?.isWordLookup == true
            && modelRuns.contains { !$0.model.isDirectTranslation }
    }

    public var displayedModelRuns: [ModelRunViewState] {
        Self.sortModelRuns(
            modelRuns,
            order: preferences.modelResultOrder,
            catalog: ModelListSections.resultOrder(
                cloudModels: models, order: preferences.modelListOrder, isPro: Entitlement.shared.isPro
            )
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
            // Failures sink to the end in every order so the leading result is usable.
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
            if order == .firstCompletedFirst {
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
                    break
                }
            }
            let leftRank = ranks[lhs.element.id] ?? Int.max
            let rightRank = ranks[rhs.element.id] ?? Int.max
            return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
        }.map(\.element)
    }

    @Published public internal(set) var isLoadingConfiguration: Bool = true

    /// When set, `refreshConfiguration()` will select this action after loading.
    public internal(set) var pendingDeepLinkActionName: String?

    /// Non-nil when the target used for the current request differs from
    /// the persisted target preference, either because Match resolved to a
    /// concrete language or because the user picked a one-shot override.
    @Published public internal(set) var resolvedTargetLanguage: TargetLanguageOption?

    /// The detected (or user-pinned) source language, refreshed live while typing and on each request.
    @Published public internal(set) var detectedSourceLanguage: SourceLanguageOption?
    @Published public internal(set) var suggestedSourceLanguages: [SourceLanguageOption] = []
    @Published public internal(set) var alternativeTargetLanguage: TargetLanguageOption?
    @Published public internal(set) var sourceLanguageOverride: SourceLanguageOption?

    /// True when the automatic target skipped the first language because the source already is that language.
    @Published public internal(set) var isMatchTargetFallback = false

    var languagePreviewTask: Task<Void, Never>?

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
    public internal(set) var appleTranslateSourceLanguage: Locale.Language?

    /// Context captured when an Apple Translate request is pending, so that the
    /// `.translationTask()` callback in HomeView can relay it back.
    public internal(set) var pendingAppleTranslateText: String?
    public internal(set) var pendingAppleTranslateAction: ActionConfig?
    public internal(set) var pendingAppleTranslateRequestID: UUID?
    var pendingAppleTranslateResolvedTarget: TargetLanguageOption?

    /// When non-nil, bypasses automatic language detection and uses this
    /// target language for the current translation.
    var targetLanguageOverride: TargetLanguageOption?
    var currentTextTarget: TargetLanguageOption?
    public var hasCurrentTextTarget: Bool { currentTextTarget != nil }

    /// Optional handler invoked on macOS to route Apple Translate requests through a
    /// real NSWindow (required for TranslationSession to work outside an NSPopover).
    /// Set by the host app (AITranslator) via `AppleTranslationWindowManager`.
    public var appleTranslationRequestHandler: ((Locale.Language?, TargetLanguageOption) -> Void)?

    /// True when the last Apple Translate run stopped because its language pack is not
    /// downloaded. The result card then offers a Download button instead of Retry.
    @Published public internal(set) var appleTranslateNeedsLanguageDownload = false

    /// Set by the Download button so the next Apple Translate run may present the
    /// system download sheet; otherwise a missing pack fails without any system UI.
    var allowsAppleTranslateDownloadPrompt = false

    // MARK: - TTS Playback State

    @Published public internal(set) var speakingModels: Set<String> = []
    @Published public internal(set) var isSpeakingInputText: Bool = false
    /// Set to `true` when the user triggers an action but has not yet accepted data sharing consent.
    @Published public var showDataConsentRequest: Bool = false
    /// Set to `true` when the satisfaction prompt toast should be displayed.
    @Published public var showSatisfactionPrompt: Bool = false
    /// Set to `true` when the system App Store review prompt should be requested directly.
    @Published public var requestSystemReview: Bool = false
    /// Incremented each time a translation request completes with at least one success.
    @Published public internal(set) var successfulTranslationCount: Int = 0
    let ttsService: TTSPreviewService

    public let placeholderHint: String = NSLocalizedString(
        "Enter text and choose an action to get started",
        comment: "Hint shown above the action list when no input or results exist"
    )
    public let inputPlaceholder: String = NSLocalizedString(
        "Enter text to translate or process...",
        comment: "Placeholder text for the main input editor"
    )

    let configurationStore: AppConfigurationStore
    let llmService: LLMService
    let preferences: AppPreferences
    let premiumAccess: @MainActor () -> Bool
    var cancellables = Set<AnyCancellable>()
    var currentRequestTask: Task<Void, Never>?
    var appleTranslateWatchdogTask: Task<Void, Never>?
    var activeRequestContext: RequestContext?
    var requestGenerationTracker = RequestGenerationTracker()

    // Per-run retry support (so tapping retry on one card doesn't re-run every model)
    var perRunTasks: [String: Task<Void, Never>] = [:]
    var allActions: [ActionConfig]
    public internal(set) var currentRequestInputText: String = ""
    var currentRequestImages: [ImageAttachment] = []
    /// When true, `performSelectedAction()` will be called automatically once models finish loading.
    var pendingAutoAction: Bool = false

    struct RequestContext {
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
        /// The input was answered as a dictionary entry, so sentence pairs do not apply.
        var isWordLookup = false

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
            context.isWordLookup = isWordLookup
            return context
        }
    }

    var pendingAppleTranslateContext: RequestContext?
    var pendingAppleTranslateRunToken: UUID?

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

    public convenience init(
        configurationStore: AppConfigurationStore? = nil,
        llmService: LLMService = .shared,
        preferences: AppPreferences = .shared,
        ttsService: TTSPreviewService = .shared,
        supportsAppleTranslate: Bool = true,
        onboardingTrialModels: [ModelConfig] = []
    ) {
        self.init(
            configurationStore: configurationStore,
            llmService: llmService,
            preferences: preferences,
            ttsService: ttsService,
            supportsAppleTranslate: supportsAppleTranslate,
            onboardingTrialModels: onboardingTrialModels,
            initialModels: nil
        )
    }

    init(
        configurationStore: AppConfigurationStore? = nil,
        llmService: LLMService = .shared,
        preferences: AppPreferences = .shared,
        ttsService: TTSPreviewService = .shared,
        supportsAppleTranslate: Bool = true,
        onboardingTrialModels: [ModelConfig] = [],
        initialModels: [ModelConfig]?,
        premiumAccess: @escaping @MainActor () -> Bool = { Entitlement.shared.isPro }
    ) {
        let store = configurationStore ?? .shared
        self.configurationStore = store
        self.llmService = llmService
        self.preferences = preferences
        self.premiumAccess = premiumAccess
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
            if let initialModels {
                models = initialModels
                isLoadingModels = false
            } else {
                loadModels()
            }

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
                    guard let self else { return }
                    // The endpoint can be configured after this catalog was loaded.
                    self.models = self.models.filter { !$0.isCustomEndpoint }
                        + CustomEndpointService.shared.modelConfigs
                    self.updateEnabledModels()
                }
                .store(in: &cancellables)
        }

        isLoadingConfiguration = false

        preferences.$sourceLanguage.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.sourceLanguageOverride = nil
                self?.scheduleLanguagePreviewRefresh()
            }
            .store(in: &cancellables)

        preferences.$targetLanguage.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.currentTextTarget = nil
                self?.scheduleLanguagePreviewRefresh()
            }
            .store(in: &cancellables)

        Publishers.Merge3(
            preferences.$modelResultOrder.dropFirst().map { _ in () },
            preferences.$modelListOrder.dropFirst().map { _ in () },
            Entitlement.shared.$state.map(\.isPro).removeDuplicates().dropFirst().map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        .store(in: &cancellables)
    }

    deinit {
        currentRequestTask?.cancel()
        appleTranslateWatchdogTask?.cancel()
        perRunTasks.values.forEach { $0.cancel() }
    }

    /// Models the next run uses, as the composer's model button names them.
    public func selectedDisplayModels(enabledIDs: Set<String>, isPro: Bool) -> [ModelConfig] {
        let resolved = resolveSelection(storedIDs: enabledIDs, isPremium: isPro)
        let displayModels = modelsForRun(enabledIDs: resolved.enabledIDs, catalogModels: resolved.catalogModels)
        let ranks = Dictionary(
            ModelListSections.resultOrder(cloudModels: models, order: preferences.modelListOrder, isPro: isPro)
                .enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return displayModels.enumerated().sorted { lhs, rhs in
            let left = ranks[lhs.element.id] ?? Int.max
            let right = ranks[rhs.element.id] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
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
        // Models need not be loaded yet (pendingAutoAction queues the request);
        // only an empty input is unsendable.
        return !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty
    }

    /// Direct translation services only translate, so prompt-based actions need an AI model.
    public func requiresAIModelSelection(for action: ActionConfig) -> Bool {
        guard !action.supportsAppleTranslate, onboardingTrialModels.isEmpty, !models.isEmpty,
              preferences.enabledModelIDs.contains(where: ModelConfig.isDirectTranslationID) else { return false }
        return getEnabledModels().allSatisfy(\.isDirectTranslation)
    }

    /// The usable IDs and catalog models for a stored selection. The request path and the
    /// composer's model button both resolve through here so they cannot disagree.
    func resolveSelection(
        storedIDs: Set<String>,
        isPremium: Bool
    ) -> (enabledIDs: Set<String>, catalogModels: [ModelConfig]) {
        let modelCatalog = models
        let enabledIDs = ModelSelectionPolicy.effectiveEnabledIDs(
            enabledIDs: storedIDs.isEmpty ? ModelConfig.defaultEnabledModelIDs(cloudModels: modelCatalog) : storedIDs,
            availableModels: modelCatalog,
            isPro: isPremium
        )
        var available = modelCatalog.filter { enabledIDs.contains($0.id) }

        // Fallback: if the selection holds no catalog model (e.g. stale IDs), use the default
        // free model so the send button never silently fails.
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
        return (enabledIDs, available)
    }

    /// The single source of truth for which models a run uses, shared by the composer's model button
    /// and the request fan-out. Direct translation services only apply to translation actions.
    /// In SwiftUI contexts the view layer provides an Apple session via `.translationTask()`; in
    /// non-SwiftUI contexts (e.g. the extension) the installed-language-pack path is used instead.
    func modelsForRun(
        enabledIDs: Set<String>,
        catalogModels: [ModelConfig],
        allowModelFallback: Bool = false
    ) -> [ModelConfig] {
        let supportsDirectTranslation = selectedAction?.supportsAppleTranslate == true
        let appleAvailable = AppleTranslationService.shared.isAvailable
        var available: [ModelConfig] = []
        if supportsDirectTranslation, appleAvailable, enabledIDs.contains(ModelConfig.appleTranslateID) {
            available.append(ModelConfig.appleTranslate)
        }
        if supportsDirectTranslation, enabledIDs.contains(ModelConfig.microsoftTranslateID) {
            available.append(ModelConfig.microsoftTranslate)
        }
        if enabledIDs.contains(ModelConfig.privateCloudModelID) {
            available.append(ModelConfig.privateCloudModel)
        }
        if enabledIDs.contains(ModelConfig.foundationModelID) {
            available.append(ModelConfig.foundationModel)
        }
        available.append(contentsOf: catalogModels)

        // Last resort when neither the server nor the user settings yield a model.
        // `allowModelFallback` callers cannot wait for the catalog request to finish.
        if available.isEmpty, !isLoadingModels || allowModelFallback, supportsDirectTranslation, appleAvailable {
            available = [ModelConfig.appleTranslate]
        }
        return available
    }

    func getEnabledModels(
        cachedIsPremium: Bool? = nil,
        allowModelFallback: Bool = false
    ) -> [ModelConfig] {
        // Onboarding trial mode: hard-pin to the model the user picked, skip
        // the entire preferences/premium gating dance so the trial can still
        // run on a premium model even though the user hasn't subscribed yet.
        if !onboardingTrialModels.isEmpty {
            return onboardingTrialModels
        }

        let storedEnabledIDs = preferences.enabledModelIDs
        let isPremium = cachedIsPremium ?? premiumAccess()

        logger
            .debug(
                "getEnabledModels: enabledIDs=\(storedEnabledIDs, privacy: .public), models.count=\(self.models.count, privacy: .public), isPremium=\(isPremium, privacy: .public)"
            )

        let (enabledIDs, catalogModels) = resolveSelection(storedIDs: storedEnabledIDs, isPremium: isPremium)
        let available = modelsForRun(
            enabledIDs: enabledIDs,
            catalogModels: catalogModels,
            allowModelFallback: allowModelFallback
        )

        logger.debug("getEnabledModels result: \(available.map(\.id), privacy: .public)")
        return available
    }

    func loadModels() {
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
                    self.updateEnabledModels(prunesMissing: true)

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

    /// `prunesMissing` drops selections the catalog does not contain. Only this view model's own
    /// fetch may do that: elsewhere the catalog can be older than the one the picker just loaded.
    func updateEnabledModels(prunesMissing: Bool = false) {
        let availableIDs = Set(models.map { $0.id })
        guard hasFetchedModels, !availableIDs.isEmpty else { return }

        let currentEnabled = preferences.enabledModelIDs
        var resolved = currentEnabled
        if prunesMissing {
            // Preserve built-in model IDs that do not come from the cloud model list.
            let builtInIDs = currentEnabled.filter {
                ModelConfig.isDirectTranslationID($0)
                    || ModelConfig.isFoundationModelID($0)
            }
            resolved = currentEnabled.intersection(availableIDs).union(builtInIDs)
        }
        if resolved.isEmpty {
            resolved = ModelConfig.defaultEnabledModelIDs(cloudModels: models)
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
        let submittedAt = ContinuousClock.now
        cancelActiveRequest(clearResults: false)
        if refreshEntitlement {
            // StoreManager already follows `Transaction.updates`, so the cached
            // entitlement is current; refresh without delaying this request.
            Task { await Entitlement.shared.refresh() }
        }
        // Per-model requests reuse the cached result.
        performSelectedActionWithCurrentEntitlement(
            refreshEntitlement: false,
            allowModelFallback: allowModelFallback,
            submittedAt: submittedAt
        )
    }

    func performSelectedActionWithCurrentEntitlement(
        refreshEntitlement: Bool,
        allowModelFallback: Bool,
        submittedAt: ContinuousClock.Instant
    ) {
        // Check data sharing consent before sending any data (macOS only).
        #if os(macOS)
            if !preferences.hasAcceptedDataSharing {
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
        let isWordLookup = preferences.wordLookupEnabled
            && action.id == BuiltInActionCatalog.translateActionID
            && WordLookupDetector.isWordOrPhrase(rawText)
        if isWordLookup {
            action.prompt = BuiltInActionCatalog.wordLookupPrompt
        }

        currentRequestInputText = text
        currentRequestImages = attachedImages

        let cachedIsPremium = premiumAccess()
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
                    : String(localized: "No models available. Please select a model in the Models tab.")
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

        setResolvedTargetLanguage(nil, reason: "Starting selected action request")
        setDetectedSourceLanguage(nil, reason: "Starting selected action request")

        let generation = UUID()
        var context = RequestContext(
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
        context.isWordLookup = isWordLookup
        let runTokens = Dictionary(uniqueKeysWithValues: modelsToUse.map { ($0.id, UUID()) })
        activeRequestContext = context
        requestGenerationTracker.begin(generation: generation, runTokens: runTokens)

        modelRuns = modelsToUse.map {
            ModelRunViewState(
                model: $0, timingTrace: TranslationTimingTrace(startedAt: submittedAt),
                status: .running(start: Date()),
                requestLanguages: context.languages
            )
        }

        // Runs that open as sentence pairs request them directly instead of the whole translation first.
        let sentencePairsRunIndices = preferences.defaultsToSentencePairs
            && action.id == BuiltInActionCatalog.translateActionID
            ? modelRuns.indices.filter { canShowSentencePairs(for: modelRuns[$0]) }
            : []
        let sentencePairsModelIDs = Set(sentencePairsRunIndices.map { modelRuns[$0].id })
        let primaryModels = modelsToUse.filter { !sentencePairsModelIDs.contains($0.id) }

        if !primaryModels.isEmpty {
            currentRequestTask = Task { [weak self] in
                await self?.executeRequest(
                    context: context,
                    models: primaryModels,
                    runTokens: runTokens,
                    taskOwner: .primary
                )
            }
        }
        if let sentencePairsContext = requestContext(for: .sentencePairs, base: context) {
            for index in sentencePairsRunIndices {
                modelRuns[index].presentation = .sentencePairs
                startSingleRun(at: index, context: sentencePairsContext)
            }
        }
    }

    /// Retry a single model run (used by the per-result-card Retry button).
    /// This should NOT cancel or restart other model runs.
    public func retryRun(runID: String) {
        guard let context = activeRequestContext else {
            // The no-model error card has no request context; run the selected action again.
            if modelRuns.contains(where: { $0.id == runID && $0.model.id == "error" }) {
                performSelectedAction()
            }
            return
        }
        guard let index = modelRuns.firstIndex(where: { $0.id == runID }), !context.text.isEmpty || !context.images.isEmpty,
              let runContext = requestContext(
                  for: modelRuns[index].presentation,
                  base: context
              ) else { return }
        startSingleRun(at: index, context: runContext)
    }

    /// Re-runs Apple Translate and lets it present the system language download sheet.
    public func downloadAppleTranslateLanguage(runID: String) {
        allowsAppleTranslateDownloadPrompt = true
        retryRun(runID: runID)
    }

    /// Sentence pairs are offered on AI results of plain translation actions.
    public func canShowSentencePairs(for run: ModelRunViewState) -> Bool {
        guard let context = activeRequestContext,
              context.action.outputType == .translate,
              !context.isWordLookup,
              !run.model.isDirectTranslation
        else {
            return false
        }
        return true
    }

    /// The vocabulary entry a successful translation-category result can be saved as.
    public func vocabularyDraft(forRunID runID: String) -> VocabularyDraft? {
        guard let context = activeRequestContext,
              context.action.category == .translation,
              context.images.isEmpty,
              let run = modelRuns.first(where: { $0.id == runID }),
              case let .success(result) = run.status
        else {
            return nil
        }
        let draft = VocabularyDraft(
            term: context.text,
            translation: result.copyText,
            sourceLanguageCode: context.languages.sourceCode,
            targetLanguageCode: context.languages.target.rawValue
        )
        return draft.term.isEmpty || draft.translation.isEmpty ? nil : draft
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

    func requestContext(
        for presentation: ModelRunViewState.Presentation,
        base context: RequestContext
    ) -> RequestContext? {
        switch presentation {
        case .standard:
            return context
        case .sentencePairs:
            return context.withAction(
                BuiltInActionCatalog.sentenceTranslateAction,
                historyRequestID: context.sentencePairsHistoryRequestID
            )
        }
    }

    func startSingleRun(at index: Int, context: RequestContext, keepsResultOrder: Bool = false) {
        let runID = modelRuns[index].id
        let model = modelRuns[index].model

        // Cancel any in-flight retry for this run only
        perRunTasks[runID]?.cancel()

        let runToken = UUID()
        requestGenerationTracker.retry(runID: runID, token: runToken)

        // Reset UI state for this specific run
        modelRuns[index].markdownStreamSource.reset()
        modelRuns[index].timingTrace = TranslationTimingTrace()
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

        if let timing = modelRuns.first(where: { $0.id == runID })?.timingTrace?.snapshot(),
           var record = NetworkRequestLogger.shared.records.first(where: {
               $0.requestHeaders.contains { $0.key.caseInsensitiveCompare("X-Request-ID") == .orderedSame
                   && $0.value == timing.requestID
               }
           })
        {
            record.translationTiming = timing
            selectedDebugNetworkRecord = record
            return
        }

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
}
