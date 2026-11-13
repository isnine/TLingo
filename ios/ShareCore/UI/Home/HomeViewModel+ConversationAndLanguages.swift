//
//  HomeViewModel+ConversationAndLanguages.swift
//  ShareCore
//

import Combine
import Foundation
import os
import SwiftUI
import Translation
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "HomeViewModel")

@MainActor
public extension HomeViewModel {
    // MARK: - Snapshot Mock Data

    /// Populates the view model with realistic-looking mock data for
    /// Fastlane App Store screenshot capture.
    internal func populateSnapshotData() {
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
            preferences.setEnabledModelIDs(Set(modelIDs))
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
    func createSnapshotConversationSession() -> ConversationSession? {
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

    var defaultAction: ActionConfig? {
        actions.first
    }

    // MARK: - State Snapshot (cross-window sync)

    /// A minimal snapshot of the user-visible translation state, used to hand off
    /// in-flight translation context (input + selected action + results) from one
    /// HomeViewModel instance to another (e.g. menu bar popover → main window).
    struct StateSnapshot {
        public let inputText: String
        public let currentRequestInputText: String
        public let selectedActionID: ActionConfig.ID?
        public let modelRuns: [ModelRunViewState]

        public init(
            inputText: String,
            currentRequestInputText: String,
            selectedActionID: ActionConfig.ID?,
            modelRuns: [ModelRunViewState]
        ) {
            self.inputText = inputText
            self.currentRequestInputText = currentRequestInputText
            self.selectedActionID = selectedActionID
            self.modelRuns = modelRuns
        }
    }

    func captureStateSnapshot() -> StateSnapshot {
        StateSnapshot(
            inputText: inputText,
            currentRequestInputText: currentRequestInputText,
            selectedActionID: selectedActionID,
            modelRuns: modelRuns
        )
    }

    /// Adopt a snapshot from another HomeViewModel. Cancels any in-flight requests,
    /// overwrites input/action/results, but does NOT trigger a new translation.
    func adoptStateSnapshot(_ snapshot: StateSnapshot) {
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

    /// Manually override the target language for the next translation and re-execute.
    /// Used by the language switcher menu. Target is never automatically redirected,
    /// so `resolvedTargetLanguage` stays nil — the override is consumed once on the next request.
    func overrideTargetLanguage(
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
    func clearDetectedSourceLanguage() {
        setDetectedSourceLanguage(nil, reason: "User changed source language")
    }

    func swapInputLanguages() {
        let source = preferences.sourceLanguage
        let target = preferences.targetLanguage
        let matchCandidates = TargetLanguageOption.matchCandidates
        let resolution = inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Self.resolveLanguages(
            text: inputText,
            sourcePreference: source,
            preferredTarget: target,
            override: nil,
            matchCandidates: matchCandidates
        )
        let concreteSource = source == .auto ? resolution?.displaySource ?? detectedSourceLanguage : source
        let concreteTarget: TargetLanguageOption? = if target == .appLanguage {
            resolution?.target ?? resolvedTargetLanguage ?? Self.resolveTargetLanguage(
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

    internal func setResolvedTargetLanguage(_ language: TargetLanguageOption?, reason: String) {
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

    internal func setTargetLanguageOverride(_ language: TargetLanguageOption?, reason: String) {
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

    internal func setDetectedSourceLanguage(_ language: SourceLanguageOption?, reason: String) {
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

    internal func logLanguageChange(field: String, from oldValue: String?, to newValue: String?, reason: String) {
        let message = LanguageChangeLog.message(
            scope: "HomeViewModel",
            field: field,
            from: oldValue,
            to: newValue,
            reason: reason
        )
        logger.debug("\(message, privacy: .public)")
    }

    func toggleDiffDisplay(for runID: String) {
        guard let index = modelRuns.firstIndex(where: { $0.id == runID }) else {
            return
        }
        modelRuns[index].showDiff.toggle()
    }

    func hasDiff(for runID: String) -> Bool {
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

    func isDiffShown(for runID: String) -> Bool {
        guard let run = modelRuns.first(where: { $0.id == runID }) else {
            return false
        }
        return run.showDiff
    }

    // MARK: - TTS Playback

    /// Speaks the result text for a specific run
    func speakResult(_ text: String, runID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !speakingModels.contains(runID) else { return }

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
    func speakInputText() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSpeakingInputText else { return }

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
    func isSpeaking(runID: String) -> Bool {
        speakingModels.contains(runID)
    }

    /// Stop any current TTS playback
    func stopSpeaking() {
        ttsService.stopPlayback()
        speakingModels.removeAll()
        isSpeakingInputText = false
    }

    // MARK: - Continue Conversation

    /// Creates a ``ConversationSession`` from a completed model run,
    /// reconstructing the original prompt messages so the conversation
    /// starts with full context.
    func createConversation(from run: ModelRunViewState) -> ConversationSession? {
        guard let action = activeRequestContext?.action ?? selectedAction else { return nil }

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

        let text = activeRequestContext?.text ?? currentRequestInputText
        let languages = run.requestLanguages ?? activeRequestContext?.languages ?? ResolvedLanguagePair(
            target: resolvedTargetLanguage ?? preferences.targetLanguage,
            sourceCode: detectedSourceLanguage?.rawValue
        )
        let promptMessages = action.promptMessages(
            text: text,
            targetLanguage: languages.targetLanguageDescriptor,
            sourceLanguage: languages.sourceLanguageDescriptor
        )
        if let system = promptMessages.system {
            chatMessages.append(ChatMessage(role: "system", content: system))
        }
        chatMessages.append(ChatMessage(
            role: "user",
            content: promptMessages.user,
            images: activeRequestContext?.images ?? currentRequestImages
        ))

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
    func createConversationWithFollowUp(from run: ModelRunViewState, followUp: String) -> ConversationSession? {
        guard var session = createConversation(from: run) else { return nil }
        session.pendingInput = followUp
        return session
    }

    /// Creates a conversation session with the selected text as context,
    /// without any prior translation results. Used by the extension's Chat button.
    func createContextConversation(contextText: String) -> ConversationSession? {
        guard let action = selectedAction else { return nil }
        guard let model = getEnabledModels().first(where: { !$0.isDirectTranslation }) else {
            modelRuns = [
                ModelRunViewState(
                    model: ModelConfig(id: "error", displayName: "Error"),
                    status: .failure(
                        message: String(localized: "This action needs an AI model. Select one in Models."),
                        duration: 0
                    )
                ),
            ]
            return nil
        }

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

    /// Result of `consumeResolvedTarget`: the resolved target language and
    /// the detected/pinned source language code (for reuse by Apple/Microsoft/LLM engines).
    internal struct ResolvedLanguagePair {
        let target: TargetLanguageOption
        /// BCP 47 source code (e.g. "en", "zh-Hans"), or nil when detection failed.
        let sourceCode: String?

        var targetLanguageDescriptor: String {
            target.promptDescriptor
        }

        /// Human-readable source descriptor for LLM prompts, e.g. "日本語 (Japanese)".
        /// Empty when source is unknown (auto-detect failed).
        var sourceLanguageDescriptor: String {
            sourceCode.flatMap(HomeViewModel.sourceLanguageOption(for:))?.promptDescriptor ?? ""
        }
    }

    internal nonisolated static func sourceLanguageOption(for code: String) -> SourceLanguageOption? {
        SourceLanguageOption(rawValue: code) ?? SourceLanguageOption.allCases.first {
            $0 != .auto && SourceLanguageDetector.languagesAreSame($0.rawValue, code)
        }
    }

    internal struct TargetLanguageResolution {
        let target: TargetLanguageOption
        let displayTarget: TargetLanguageOption?
    }

    internal nonisolated static func resolveTargetLanguage(
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
    internal func consumeResolvedTarget(for text: String) -> ResolvedLanguagePair {
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

    internal struct LanguageResolution: Equatable {
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
    internal nonisolated static func resolveLanguages(
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
            sourceCode = SourceLanguageDetector.detectLocaleLanguage(of: text)?.minimalIdentifier
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
            sourceCode.flatMap(sourceLanguageOption(for:))
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

    internal func applyLanguageResolution(_ resolution: LanguageResolution?, reason: String) {
        setDetectedSourceLanguage(resolution?.displaySource, reason: "\(reason): source=\(resolution?.sourceCode ?? "nil")")
        setResolvedTargetLanguage(resolution?.displayTarget, reason: "\(reason): target resolved")
        if isMatchTargetFallback != (resolution?.isMatchFallback ?? false) {
            isMatchTargetFallback = resolution?.isMatchFallback ?? false
        }
    }

    /// Debounced so language detection runs once the user pauses typing.
    internal func scheduleLanguagePreviewRefresh() {
        languagePreviewTask?.cancel()
        languagePreviewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshLanguagePreview()
        }
    }

    internal func refreshLanguagePreview() {
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
}
