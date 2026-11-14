//
//  HomeViewModel+Execution.swift
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
extension HomeViewModel {
    /// If user chose source==target (or auto-detected source matches target), Apple Translate
    /// physically can't translate — return a localized error result instead of calling the API.
    func sameSourceAndTargetResult(
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

    func isRunStillValid(_ context: RequestContext, runID: String, runToken: UUID) -> Bool {
        requestGenerationTracker.accepts(
            generation: context.generation,
            runID: runID,
            token: runToken
        )
    }

    func executeRequest(
        context: RequestContext,
        models: [ModelConfig],
        runTokens: [String: UUID],
        taskOwner: RequestTaskOwner
    ) async {
        defer {
            finishRequestTask(taskOwner, context: context)
        }
        guard !Task.isCancelled else { return }

        // Separate direct translation services from cloud LLM models.
        let cloudModels = models.filter { !$0.isDirectTranslation }
        let hasAppleTranslate = models.contains { $0.id == ModelConfig.appleTranslateID }
        let microsoftModels = models.filter { $0.id == ModelConfig.microsoftTranslateID }
        logger
            .debug(
                "executeRequest: \(models.count, privacy: .public) models, apple=\(hasAppleTranslate, privacy: .public)"
            )

        await withTaskGroup(of: Void.self) { group in
            if hasAppleTranslate, runTokens[ModelConfig.appleTranslateID] != nil {
                group.addTask { @MainActor [weak self] in
                    await self?.runAppleTranslate(context: context, runTokens: runTokens)
                }
            }
            for model in microsoftModels {
                group.addTask { @MainActor [weak self] in
                    await self?.runMicrosoftTranslate(model: model, context: context, runTokens: runTokens)
                }
            }
            if !cloudModels.isEmpty {
                group.addTask { @MainActor [weak self] in
                    await self?.runCloudModels(cloudModels, context: context, runTokens: runTokens)
                }
            }
        }
    }

    func clearPendingAppleTranslate() {
        appleTranslateWatchdogTask?.cancel()
        appleTranslateWatchdogTask = nil
        pendingAppleTranslateText = nil
        pendingAppleTranslateAction = nil
        pendingAppleTranslateRequestID = nil
        pendingAppleTranslateResolvedTarget = nil
        pendingAppleTranslateContext = nil
        pendingAppleTranslateRunToken = nil
        appleTranslateSourceLanguage = nil
        appleTranslateTargetLanguage = nil
    }

    func applyDirectFailure(
        _ error: LocalProviderError,
        modelID: String = ModelConfig.appleTranslateID,
        duration: TimeInterval = 0,
        context: RequestContext,
        runToken: UUID
    ) {
        let result = ModelExecutionResult(modelID: modelID, duration: duration, response: .failure(error))
        apply(result: result, context: context, runToken: runToken, allowDiff: false)
    }

    /// Translates with the installed language packs (no SwiftUI session) and records the result.
    func translateWithInstalledPack(
        context: RequestContext,
        source: Locale.Language?,
        target: Locale.Language,
        runToken: UUID
    ) async throws {
        let result: ModelExecutionResult
        if context.action.outputType == .sentencePairs {
            result = try await AppleTranslationService.shared.translateSentencesWithInstalledLanguages(
                text: context.text, source: source, target: target
            )
        } else {
            result = try await AppleTranslationService.shared.translateWithInstalledLanguages(
                text: context.text, source: source, target: target
            )
        }
        guard isRunStillValid(context, runID: result.modelID, runToken: runToken) else { return }
        apply(result: result, context: context, runToken: runToken, allowDiff: false)
        saveHistoryIfSuccessful(result, context: context, runToken: runToken)
    }

    func failAppleTranslate(
        _ error: Error,
        label: String,
        context: RequestContext,
        source: Locale.Language?,
        runToken: UUID
    ) {
        let resolvedTarget = context.languages.target
        logger
            .error(
                "\(label, privacy: .public) failed: \(String(describing: error), privacy: .public), source=\(source?.minimalIdentifier ?? "auto", privacy: .public), target=\(resolvedTarget.localeLanguage.minimalIdentifier, privacy: .public)"
            )
        guard isRunStillValid(context, runID: ModelConfig.appleTranslateID, runToken: runToken) else { return }
        applyDirectFailure(
            .translationFailed(AppleTranslationErrorFormatter.describe(error, source: source, target: resolvedTarget)),
            context: context,
            runToken: runToken
        )
    }

    func runAppleTranslate(context: RequestContext, runTokens: [String: UUID]) async {
        guard let runToken = runTokens[ModelConfig.appleTranslateID] else { return }
        let action = context.action
        let resolved = context.languages
        let resolvedTarget = resolved.target
        let allowsDownloadPrompt = allowsAppleTranslateDownloadPrompt
        allowsAppleTranslateDownloadPrompt = false
        appleTranslateNeedsLanguageDownload = false

        guard action.supportsAppleTranslate else {
            // Unsupported action — show inline error immediately.
            logger.error("Apple Translate: action '\(action.name, privacy: .public)' does not support Apple Translate")
            applyDirectFailure(.unsupportedAction, context: context, runToken: runToken)
            return
        }
        if let shortCircuit = sameSourceAndTargetResult(sourceCode: resolved.sourceCode, target: resolvedTarget) {
            apply(result: shortCircuit, context: context, runToken: runToken, allowDiff: false)
            return
        }

        let sourceLocale: Locale.Language? = resolved.sourceCode.map { Locale.Language(identifier: $0) }
        let targetLocale = resolvedTarget.localeLanguage

        guard supportsAppleTranslate else {
            // Non-SwiftUI context (e.g. extension): use TranslationSession(installedSource:target:)
            // directly. Only works if language packs are already installed.
            do {
                try await translateWithInstalledPack(
                    context: context, source: sourceLocale, target: targetLocale, runToken: runToken
                )
            } catch {
                failAppleTranslate(
                    error,
                    label: "Apple Translate (non-SwiftUI path)",
                    context: context,
                    source: sourceLocale,
                    runToken: runToken
                )
            }
            return
        }

        // SwiftUI context: prefer the direct TranslationSession(installedSource:target:) path when the
        // language pack is already installed (or auto-source with supported target); fall back to
        // .translationTask() only for a download.
        do {
            let status = try await AppleTranslationService.shared.languageAvailabilityStatus(
                source: sourceLocale, target: targetLocale
            )
            guard !Task.isCancelled,
                  isRunStillValid(context, runID: ModelConfig.appleTranslateID, runToken: runToken)
            else { return }
            if status == .installed || (sourceLocale == nil && status == .supported) {
                // Language pack already on device (or auto-detected source with supported target) — skip SwiftUI bridge.
                do {
                    try await translateWithInstalledPack(
                        context: context, source: sourceLocale, target: targetLocale, runToken: runToken
                    )
                } catch TranslationError.notInstalled where sourceLocale == nil {
                    guard !Task.isCancelled,
                          isRunStillValid(context, runID: ModelConfig.appleTranslateID, runToken: runToken)
                    else { return }
                    if !allowsDownloadPrompt {
                        markAppleTranslateNeedsDownload(
                            source: sourceLocale, target: resolvedTarget, context: context, runToken: runToken
                        )
                    } else {
                        requestAppleTranslationDownload(
                            context: context, source: sourceLocale, status: status, runToken: runToken
                        )
                    }
                }
            } else if status == .supported, !allowsDownloadPrompt {
                markAppleTranslateNeedsDownload(
                    source: sourceLocale, target: resolvedTarget, context: context, runToken: runToken
                )
            } else if status == .unsupported {
                // No download can fix this; .translationTask would only wait out the watchdog.
                applyDirectFailure(
                    .unsupportedLanguage(
                        AppleTranslationErrorFormatter.withLanguagePair(
                            String(localized: "Apple Translate does not support the selected language pair."),
                            source: sourceLocale,
                            target: resolvedTarget
                        )
                    ),
                    context: context,
                    runToken: runToken
                )
            } else {
                requestAppleTranslationDownload(
                    context: context,
                    source: sourceLocale,
                    status: status,
                    runToken: runToken
                )
            }
        } catch {
            failAppleTranslate(
                error,
                label: "Apple Translate",
                context: context,
                source: sourceLocale,
                runToken: runToken
            )
        }
    }

    func markAppleTranslateNeedsDownload(
        source sourceLocale: Locale.Language?,
        target resolvedTarget: TargetLanguageOption,
        context: RequestContext,
        runToken: UUID
    ) {
        // Ask in the result card before the system download sheet appears.
        appleTranslateNeedsLanguageDownload = true
        applyDirectFailure(
            .translationFailed(
                AppleTranslationErrorFormatter.withLanguagePair(
                    String(localized: "Apple Translate needs to download this language pair before translating."),
                    source: sourceLocale,
                    target: resolvedTarget
                )
            ),
            context: context,
            runToken: runToken
        )
    }

    /// Language pack not installed: hand off to `.translationTask()` (which shows the download UI)
    /// and fail the run if it never responds.
    func requestAppleTranslationDownload(
        context: RequestContext,
        source sourceLocale: Locale.Language?,
        status: LanguageAvailability.Status,
        runToken: UUID
    ) {
        let resolvedTarget = context.languages.target
        pendingAppleTranslateText = context.text
        pendingAppleTranslateAction = context.action
        pendingAppleTranslateRequestID = context.historyRequestID
        pendingAppleTranslateResolvedTarget = resolvedTarget
        pendingAppleTranslateContext = context
        pendingAppleTranslateRunToken = runToken
        appleTranslateSourceLanguage = sourceLocale
        appleTranslateTargetLanguage = resolvedTarget
        logger
            .debug(
                "Apple Translate: published target=\(resolvedTarget.englishName, privacy: .public), starting \(AppleTranslationService.operationTimeoutSeconds, privacy: .public)s timeout watchdog"
            )
        appleTranslationRequestHandler?(sourceLocale, resolvedTarget)

        appleTranslateWatchdogTask?.cancel()
        appleTranslateWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppleTranslationService.operationTimeoutSeconds))
            guard let self,
                  !Task.isCancelled,
                  self.pendingAppleTranslateContext?.generation == context.generation,
                  self.pendingAppleTranslateRunToken == runToken
            else { return }
            logger
                .error(
                    "Apple Translate watchdog fired — .translationTask() did not respond in \(AppleTranslationService.operationTimeoutSeconds, privacy: .public)s, source=\(sourceLocale?.minimalIdentifier ?? "auto", privacy: .public), target=\(resolvedTarget.rawValue, privacy: .public), status=\(String(describing: status), privacy: .public)"
                )
            self.clearPendingAppleTranslate()
            guard self.isRunStillValid(context, runID: ModelConfig.appleTranslateID, runToken: runToken) else { return }
            self.applyDirectFailure(
                .translationFailed(
                    AppleTranslationErrorFormatter.withLanguagePair(
                        "Apple Translate timed out after \(AppleTranslationService.operationTimeoutSeconds) seconds. Language pack may not be available.",
                        source: sourceLocale,
                        target: resolvedTarget
                    )
                ),
                duration: TimeInterval(AppleTranslationService.operationTimeoutSeconds),
                context: context,
                runToken: runToken
            )
        }
    }

    func runMicrosoftTranslate(model: ModelConfig, context: RequestContext, runTokens: [String: UUID]) async {
        guard let runToken = runTokens[model.id] else { return }
        let resolved = context.languages
        let resolvedTarget = resolved.target
        guard context.action.supportsAppleTranslate else {
            applyDirectFailure(.unsupportedAction, modelID: model.id, context: context, runToken: runToken)
            return
        }
        if let shortCircuit = sameSourceAndTargetResult(
            sourceCode: resolved.sourceCode,
            target: resolvedTarget,
            modelID: model.id
        ) {
            apply(result: shortCircuit, context: context, runToken: runToken, allowDiff: false)
            return
        }
        guard let targetCode = MicrosoftTranslateService.translatorCode(for: resolvedTarget.rawValue) else {
            applyDirectFailure(
                .unsupportedLanguage(
                    AppleTranslationErrorFormatter.withLanguagePair(
                        String(localized: "Microsoft Translate does not support the selected language."),
                        sourceCode: resolved.sourceCode,
                        target: resolvedTarget
                    )
                ),
                modelID: model.id,
                context: context,
                runToken: runToken
            )
            return
        }
        // An unsupported source is left to Microsoft's own detection.
        let sourceCode: String? = resolved.sourceCode.flatMap(MicrosoftTranslateService.translatorCode(for:))
        let timingTrace = modelRuns.first { $0.id == model.id }?.timingTrace
        let result = await MicrosoftTranslateService.shared.translate(
            text: context.text, sourceCode: sourceCode, targetCode: targetCode, timingTrace: timingTrace
        )
        guard !Task.isCancelled,
              isRunStillValid(context, runID: result.modelID, runToken: runToken)
        else { return }
        apply(result: result, context: context, runToken: runToken, allowDiff: false)
        saveHistoryIfSuccessful(result, context: context, runToken: runToken)
    }

    /// Runs cloud LLM models through `LLMService`, streaming partial output into their runs.
    func runCloudModels(
        _ cloudModels: [ModelConfig],
        context: RequestContext,
        runTokens: [String: UUID]
    ) async {
        let text = context.text
        let action = context.action
        let resolved = context.languages
        let coalescers = Dictionary(uniqueKeysWithValues: cloudModels.map { model in
            (model.id, StreamingUpdateCoalescer { [weak self] update in
                guard let self, let token = runTokens[model.id],
                      self.isRunStillValid(context, runID: model.id, runToken: token),
                      let index = self.modelRuns.firstIndex(where: { $0.id == model.id })
                else { return }
                let now = Date()
                let startDate = self.modelRuns[index].startDate ?? now
                self.modelRuns[index].timingTrace?.mark(.firstUIUpdate)
                if self.modelRuns[index].firstOutputAt == nil {
                    self.modelRuns[index].firstOutputAt = now
                }
                switch update {
                case let .text(text):
                    self.modelRuns[index].markdownStreamSource.yield(text)
                    self.modelRuns[index].status = .streaming(text: text, start: startDate)
                case let .sentencePairs(pairs):
                    self.modelRuns[index].status = .streamingSentencePairs(pairs: pairs, start: startDate)
                }
            })
        })
        defer { coalescers.values.forEach { $0.cancel() } }

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
            timingTraces: Dictionary(uniqueKeysWithValues: modelRuns.compactMap { run in
                run.timingTrace.map { (run.id, $0) }
            }),
            partialHandler: { [weak self] modelID, update in
                guard let self,
                      let runToken = runTokens[modelID],
                      self.isRunStillValid(context, runID: modelID, runToken: runToken)
                else { return }
                coalescers[modelID]?.append(update)
            },
            completionHandler: { [weak self] result in
                guard let self,
                      let runToken = runTokens[result.modelID],
                      self.isRunStillValid(context, runID: result.modelID, runToken: runToken)
                else { return }
                coalescers[result.modelID]?.flush()
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

        recordTranslationOutcome(validResults)
    }

    func recordTranslationOutcome(_ validResults: [ModelExecutionResult]) {
        let successFlags = validResults.map { result in
            if case .success = result.response {
                return true
            }
            return false
        }
        let hasSuccess = successFlags.contains(true)
        let shouldRequestReview = preferences.recordTranslationOutcomeForReview(
            succeeded: !successFlags.contains(false)
        )
        if hasSuccess {
            successfulTranslationCount += 1
            if shouldRequestReview {
                // Skip the custom prompt so two review surfaces never stack.
                preferences.markSatisfactionPromptResponded()
                requestSystemReview = true
            } else if preferences.shouldShowSatisfactionPrompt {
                showSatisfactionPrompt = true
            }
        }
    }

    var conversationModels: [ModelConfig] {
        ModelConfig.appleIntelligenceModels.filter {
            FoundationModelService.availability(for: $0).isAvailable
        } + models
    }

    func finishRequestTask(_ owner: RequestTaskOwner, context: RequestContext) {
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

    func cancelActiveRequest(clearResults: Bool, resetsLanguages: Bool = true) {
        currentRequestTask?.cancel()
        currentRequestTask = nil
        for task in perRunTasks.values {
            task.cancel()
        }
        perRunTasks.removeAll()
        activeRequestContext = nil
        requestGenerationTracker.cancel()
        clearPendingAppleTranslate()
        if resetsLanguages {
            setDetectedSourceLanguage(nil, reason: "Active request cancelled")
        }
        if clearResults {
            if !modelRuns.isEmpty {
                modelRuns = []
            }
            if resetsLanguages {
                setTargetLanguageOverride(nil, reason: "Active request cancelled and results cleared")
                sourceLanguageOverride = nil
                currentTextTarget = nil
            }
        }
    }

    // MARK: - Apple Translation Execution

    /// Called from HomeView's `.translationTask()` callback once a TranslationSession is available.
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
        clearPendingAppleTranslate()

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

    func saveHistoryIfSuccessful(
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

    func apply(
        result: ModelExecutionResult,
        context: RequestContext,
        runToken: UUID,
        allowDiff: Bool
    ) {
        guard isRunStillValid(context, runID: result.modelID, runToken: runToken),
              let index = modelRuns.firstIndex(where: { $0.id == result.modelID })
        else {
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
            modelRuns[index].status = .success(ModelRunViewState.SuccessResult(
                text: message,
                copyText: diffTarget,
                duration: result.duration,
                diff: nil,
                supplementalTexts: result.supplementalTexts,
                sentencePairs: result.sentencePairs,
                latencyBreakdown: latencyBreakdown,
                suggestedActions: result.suggestedActions,
                providerDisplayName: result.providerDisplayName
            ))
            modelRuns[index].timingTrace?.mark(.resultApplied)
            if allowDiff, context.text != diffTarget {
                Task { [weak self] in
                    let diff = await Task.detached(priority: .userInitiated) {
                        TextDiffBuilder.build(original: context.text, revised: diffTarget)
                    }.value
                    guard let self,
                          self.isRunStillValid(
                              context,
                              runID: result.modelID,
                              runToken: runToken
                          ),
                          let currentIndex = self.modelRuns.firstIndex(where: { $0.id == result.modelID }),
                          case var .success(existing) = self.modelRuns[currentIndex].status,
                          existing.text == message
                    else { return }
                    existing.diff = diff
                    self.modelRuns[currentIndex].status = .success(existing)
                }
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
            let isUnsupported = if case .unsupportedLanguage = error as? LocalProviderError {
                true
            } else {
                false
            }
            modelRuns[index].status = .failure(
                message: error.localizedDescription,
                duration: result.duration,
                responseBody: responseBody,
                isUnsupported: isUnsupported
            )
            modelRuns[index].timingTrace?.mark(.resultApplied)
            let failedRun = modelRuns.remove(at: index)
            modelRuns.append(failedRun)
        }
    }

    func refreshActions() {
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
