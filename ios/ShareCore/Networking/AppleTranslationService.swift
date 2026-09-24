//
//  AppleTranslationService.swift
//  ShareCore
//
//  Created by Codex on 2025/01/05.
//

import Foundation
import os
import SwiftUI
#if canImport(Translation)
    import Translation
#endif

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "AppleTranslation")

public enum AppleTranslationAvailabilityStrategy: Hashable, Sendable {
    case automatic
    case lowLatency
}

private final class AppleTranslationTimeoutState<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isResolved = false

    func setContinuation(_ continuation: CheckedContinuation<T, Error>) {
        var shouldResume = false
        lock.lock()
        if isResolved {
            shouldResume = true
        } else {
            self.continuation = continuation
        }
        lock.unlock()

        if shouldResume {
            continuation.resume(throwing: CancellationError())
        }
    }

    func setOperationTask(_ task: Task<Void, Never>) {
        var shouldCancel = false
        lock.lock()
        if isResolved {
            shouldCancel = true
        } else {
            operationTask = task
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        var shouldCancel = false
        lock.lock()
        if isResolved {
            shouldCancel = true
        } else {
            timeoutTask = task
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    @discardableResult
    func resolve(with result: Result<T, Error>) -> Bool {
        let continuationToResume: CheckedContinuation<T, Error>?
        let timeoutToCancel: Task<Void, Never>?
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return false
        }
        isResolved = true
        continuationToResume = continuation
        timeoutToCancel = timeoutTask
        continuation = nil
        operationTask = nil
        timeoutTask = nil
        lock.unlock()

        timeoutToCancel?.cancel()
        continuationToResume?.resume(with: result)
        return true
    }

    func cancel() {
        let continuationToResume: CheckedContinuation<T, Error>?
        let taskToCancel: Task<Void, Never>?
        let timeoutToCancel: Task<Void, Never>?
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        continuationToResume = continuation
        taskToCancel = operationTask
        timeoutToCancel = timeoutTask
        continuation = nil
        operationTask = nil
        timeoutTask = nil
        lock.unlock()

        taskToCancel?.cancel()
        timeoutToCancel?.cancel()
        continuationToResume?.resume(throwing: CancellationError())
    }
}

/// Service for using Apple's system Translation API
/// Note: TranslationSession can only be obtained via SwiftUI's .translationTask() modifier
public final class AppleTranslationService: @unchecked Sendable {
    public static let shared = AppleTranslationService()

    /// Deployment name for Apple Translation
    public static let deploymentName = "Apple Translation"
    public static let operationTimeoutSeconds = 60

    private init() {}

    // MARK: - Availability

    /// Check if Apple Translation is available on this device
    public var isAvailable: Bool {
        let available: Bool
        if #available(iOS 17.4, macOS 14.4, *) {
            available = true
        } else {
            available = false
        }
        return available
    }

    /// Returns the availability status message
    public var availabilityStatus: String {
        if isAvailable {
            return NSLocalizedString("Ready to use", comment: "Apple Translation available status")
        } else {
            return NSLocalizedString("Requires iOS 17.4+ or macOS 14.4+", comment: "Apple Translation unavailable status")
        }
    }

    // MARK: - Language Availability

    /// Check whether a specific language pair is available for translation.
    @available(iOS 17.4, macOS 14.4, *)
    public func languageAvailabilityStatus(
        source: Locale.Language?,
        target: Locale.Language,
        strategy: AppleTranslationAvailabilityStrategy = .automatic
    ) async throws -> LanguageAvailability.Status {
        let availability: LanguageAvailability
        if #available(iOS 26.4, macOS 26.4, *), strategy == .lowLatency {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
        let sourceDesc = source?.minimalIdentifier ?? "auto"
        let targetDesc = target.minimalIdentifier
        if let source {
            let status = try await Self.withOperationTimeout(operationName: "languageAvailabilityStatus") {
                await availability.status(from: source, to: target)
            }
            if status != .installed && status != .supported {
                logger
                    .error(
                        """
                        languageAvailabilityStatus: \(sourceDesc, privacy: .public) → \
                        \(targetDesc, privacy: .public) = \(String(describing: status), privacy: .public)
                        """
                    )
            }
            return status
        }
        // When source is nil we rely on auto-detection; just check the target is in supported languages.
        let supported = try await Self.withOperationTimeout(operationName: "supportedLanguages") {
            await availability.supportedLanguages
        }
        if supported.contains(where: { $0.minimalIdentifier == target.minimalIdentifier }) {
            return .supported
        }
        logger.error("languageAvailabilityStatus: target \(targetDesc, privacy: .public) not in supported list (auto source)")
        return .unsupported
    }

    // MARK: - Installed Languages

    /// Returns the set of `TargetLanguageOption`s whose translation language packs
    /// are installed on this device (checked as pairs with English).
    @available(iOS 17.4, macOS 14.4, *)
    public func refreshInstalledLanguages() async -> Set<TargetLanguageOption> {
        do {
            return try await Self.withOperationTimeout(operationName: "refreshInstalledLanguages") {
                await self.refreshInstalledLanguagesWithoutTimeout()
            }
        } catch is CancellationError {
            return []
        } catch {
            logger.error("refreshInstalledLanguages failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    @available(iOS 17.4, macOS 14.4, *)
    private func refreshInstalledLanguagesWithoutTimeout() async -> Set<TargetLanguageOption> {
        let availability = LanguageAvailability()
        let english = Locale.Language(identifier: "en")
        var installed: Set<TargetLanguageOption> = []

        for option in TargetLanguageOption.allCases where option != .appLanguage {
            let target = option.localeLanguage
            // Check en → target
            let forwardStatus = await availability.status(from: english, to: target)
            if forwardStatus == .installed {
                installed.insert(option)
            }
            // Check target → en (covers bidirectional use)
            let reverseStatus = await availability.status(from: target, to: english)
            if reverseStatus == .installed {
                installed.insert(option)
                installed.insert(.english)
            }
        }

        logger.debug("refreshInstalledLanguages: \(installed.map(\.rawValue), privacy: .public)")
        return installed
    }

    // MARK: - Translation (direct, no SwiftUI required)

    /// Translate using a directly-initialized session from installed language packs.
    /// Does NOT require `.translationTask()` — safe to call from extension contexts.
    /// Throws `LocalProviderError.unsupportedLanguagePair` if the language pack is not installed.
    @available(iOS 17.4, macOS 14.4, *)
    public func translateWithInstalledLanguages(
        text: String,
        source: Locale.Language?,
        target: Locale.Language
    ) async throws -> ModelExecutionResult {
        let resolvedSource = source
            ?? SourceLanguageDetector.detectLocaleLanguage(of: text)
            ?? SourceLanguageDetector.fallbackSourceLanguage()
        let session = TranslationSession(installedSource: resolvedSource, target: target)
        return try await translate(text: text, using: session)
    }

    /// Translate sentence pairs using a directly-initialized session from installed language packs.
    @available(iOS 17.4, macOS 14.4, *)
    public func translateSentencesWithInstalledLanguages(
        text: String,
        source: Locale.Language?,
        target: Locale.Language
    ) async throws -> ModelExecutionResult {
        let resolvedSource = source
            ?? SourceLanguageDetector.detectLocaleLanguage(of: text)
            ?? SourceLanguageDetector.fallbackSourceLanguage()
        let session = TranslationSession(installedSource: resolvedSource, target: target)
        return try await translateSentences(text: text, using: session)
    }

    @available(iOS 17.4, macOS 14.4, *)
    public func translateRealtimeSentencesWithInstalledLanguages(
        text: String,
        source: Locale.Language?,
        target: Locale.Language
    ) async throws -> ModelExecutionResult {
        guard #available(iOS 26.4, macOS 26.4, *) else {
            return try await translateSentencesWithInstalledLanguages(text: text, source: source, target: target)
        }
        let resolvedSource = source
            ?? SourceLanguageDetector.detectLocaleLanguage(of: text)
            ?? SourceLanguageDetector.fallbackSourceLanguage()
        let session = TranslationSession(
            installedSource: resolvedSource,
            target: target,
            preferredStrategy: .lowLatency
        )
        return try await translateSentences(text: text, using: session)
    }

    // MARK: - Translation

    /// Translate a single text string using the provided TranslationSession.
    @available(iOS 17.4, macOS 14.4, *)
    public func translate(
        text: String,
        using session: TranslationSession
    ) async throws -> ModelExecutionResult {
        try await Self.withOperationTimeout(operationName: "translate") {
            try await self.translateWithoutTimeout(text: text, using: session)
        }
    }

    @available(iOS 17.4, macOS 14.4, *)
    private func translateWithoutTimeout(
        text: String,
        using session: TranslationSession
    ) async throws -> ModelExecutionResult {
        let start = Date()
        logger.debug("translate called, text length: \(text.count, privacy: .public)")

        do {
            // prepareTranslation() triggers the system download UI if the language pack
            // is not yet installed (.supported status). No-op if already installed (.installed).
            try await session.prepareTranslation()
        } catch {
            logger.error("translate: prepareTranslation failed: \(String(describing: error), privacy: .public)")
            #if os(macOS)
                NotificationCenter.default.post(name: .appleTranslationPrepareCompleted, object: nil)
            #endif
            throw error
        }
        // Notify the host app that language download is done and the auxiliary window can be hidden.
        #if os(macOS)
            NotificationCenter.default.post(name: .appleTranslationPrepareCompleted, object: nil)
        #endif

        let response: TranslationSession.Response
        do {
            response = try await session.translate(text)
        } catch {
            logger.error("translate: session.translate failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        let duration = Date().timeIntervalSince(start)

        logger.debug("translate success, duration: \(duration, privacy: .public)s")
        return ModelExecutionResult(
            modelID: ModelConfig.appleTranslateID,
            duration: duration,
            response: .success(response.targetText)
        )
    }

    /// Translate text as sentence pairs using the provided TranslationSession.
    @available(iOS 17.4, macOS 14.4, *)
    public func translateSentences(
        text: String,
        using session: TranslationSession
    ) async throws -> ModelExecutionResult {
        try await Self.withOperationTimeout(operationName: "translateSentences") {
            try await self.translateSentencesWithoutTimeout(text: text, using: session)
        }
    }

    @available(iOS 17.4, macOS 14.4, *)
    private func translateSentencesWithoutTimeout(
        text: String,
        using session: TranslationSession
    ) async throws -> ModelExecutionResult {
        let start = Date()

        do {
            // prepareTranslation() triggers the system download UI if needed.
            try await session.prepareTranslation()
        } catch {
            logger.error("translateSentences: prepareTranslation failed: \(String(describing: error), privacy: .public)")
            #if os(macOS)
                NotificationCenter.default.post(name: .appleTranslationPrepareCompleted, object: nil)
            #endif
            throw error
        }
        #if os(macOS)
            NotificationCenter.default.post(name: .appleTranslationPrepareCompleted, object: nil)
        #endif

        let sentences = splitIntoSentences(text)
        logger.debug("translateSentences: \(sentences.count, privacy: .public) sentences")

        let requests = sentences.enumerated().map { index, sentence in
            TranslationSession.Request(sourceText: sentence, clientIdentifier: "\(index)")
        }

        let responses: [TranslationSession.Response]
        do {
            responses = try await session.translations(from: requests)
        } catch {
            logger.error("translateSentences: session.translations failed: \(String(describing: error), privacy: .public)")
            throw error
        }

        // Map responses back by clientIdentifier to maintain order.
        var translatedByIndex: [Int: String] = [:]
        for response in responses {
            if let id = response.clientIdentifier, let index = Int(id) {
                translatedByIndex[index] = response.targetText
            }
        }

        var pairs: [SentencePair] = []
        for (index, original) in sentences.enumerated() {
            let translation = translatedByIndex[index] ?? ""
            pairs.append(SentencePair(original: original, translation: translation))
        }

        let duration = Date().timeIntervalSince(start)
        logger.debug("translateSentences success, duration: \(duration, privacy: .public)s")
        return ModelExecutionResult(
            modelID: ModelConfig.appleTranslateID,
            duration: duration,
            response: .success(pairs.map(\.translation).joined(separator: "\n")),
            sentencePairs: pairs
        )
    }

    private static func withOperationTimeout<T>(
        operationName: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let state = AppleTranslationTimeoutState<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.setContinuation(continuation)

                let operationTask = Task {
                    do {
                        let result = try await operation()
                        state.resolve(with: .success(result))
                    } catch {
                        state.resolve(with: .failure(error))
                    }
                }
                state.setOperationTask(operationTask)

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: .seconds(operationTimeoutSeconds))
                    } catch {
                        return
                    }

                    let didTimeOut = state.resolve(
                        with: .failure(LocalProviderError.operationTimedOut(seconds: operationTimeoutSeconds))
                    )
                    if didTimeOut {
                        logger.error(
                            "\(operationName, privacy: .public) timed out after \(operationTimeoutSeconds, privacy: .public)s"
                        )
                        operationTask.cancel()
                    }
                }
                state.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            state.cancel()
        }
    }

    // MARK: - Sentence Splitting (Public utility)

    /// Split text into sentences for translation
    public func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []

        let tagger = NSLinguisticTagger(tagSchemes: [.tokenType], options: 0)
        tagger.string = text

        let range = NSRange(location: 0, length: text.utf16.count)

        tagger.enumerateTags(in: range, unit: .sentence, scheme: .tokenType, options: []) { _, tokenRange, _ in
            if let swiftRange = Range(tokenRange, in: text) {
                let sentence = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
            }
        }

        // Fallback if no sentences found
        if sentences.isEmpty, !text.isEmpty {
            // Simple fallback: split by common sentence terminators
            let pattern = "(?<=[.!?。！？])\\s+"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let splits = regex.stringByReplacingMatches(
                    in: text,
                    options: [],
                    range: range,
                    withTemplate: "\n<<<SPLIT>>>\n"
                ).components(separatedBy: "<<<SPLIT>>>")

                sentences = splits.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }

            // If still empty, treat whole text as one sentence
            if sentences.isEmpty {
                sentences = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
            }
        }
        return sentences
    }
}

// MARK: - Error Formatting

public enum AppleTranslationErrorFormatter {
    /// Build a human-readable description that always includes the underlying
    /// NSError domain + code so users can see *why* Apple Translation failed,
    /// rather than the generic localized "Translation could not be completed".
    public static func describe(_ error: Error) -> String {
        let ns = error as NSError

        // Detect "language pack must be downloaded on device" failures from the
        // system Translation framework and surface a friendlier instruction.
        if isLanguagePackMissing(ns) {
            return NSLocalizedString(
                "Please try translating in the main window and wait for the system prompt to download the target language.",
                comment: "Shown when Apple Translate cannot translate because the language pack is not installed on device"
            )
        }

        var parts: [String] = []

        // Prefer the framework's localized message when it's actually informative.
        let localized = error.localizedDescription
        if !localized.isEmpty {
            parts.append(localized)
        }

        // Append failure reason / recovery suggestion if distinct.
        if let reason = ns.localizedFailureReason, !reason.isEmpty, !parts.contains(reason) {
            parts.append(reason)
        }
        if let suggestion = ns.localizedRecoverySuggestion, !suggestion.isEmpty, !parts.contains(suggestion) {
            parts.append(suggestion)
        }

        // Underlying NSError chain (often holds the real cause).
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            let underlyingDesc = underlying.localizedDescription
            if !underlyingDesc.isEmpty, !parts.contains(underlyingDesc) {
                parts.append("Underlying: \(underlyingDesc)")
            }
            parts.append("(underlying \(underlying.domain) \(underlying.code))")
        }

        // Always show domain + code so we can diagnose unknown failures.
        parts.append("[\(ns.domain) \(ns.code)]")

        return parts.joined(separator: " — ")
    }

    public static func describe(_ error: Error, source: Locale.Language?, target: TargetLanguageOption) -> String {
        withLanguagePair(describe(error), source: source, target: target)
    }

    public static func describe(_ error: Error, sourceCode: String?, target: TargetLanguageOption) -> String {
        withLanguagePair(describe(error), sourceCode: sourceCode, target: target)
    }

    public static func withLanguagePair(_ message: String, source: Locale.Language?, target: TargetLanguageOption) -> String {
        withLanguagePair(message, languagePair: languagePairDescription(source: source, target: target))
    }

    public static func withLanguagePair(_ message: String, sourceCode: String?, target: TargetLanguageOption) -> String {
        withLanguagePair(message, languagePair: languagePairDescription(sourceCode: sourceCode, target: target))
    }

    public static func languagePairDescription(sourceCode: String?, target: TargetLanguageOption) -> String {
        "\(sourceLabel(for: sourceCode)) -> \(target.primaryLabel)"
    }

    public static func languagePairDescription(source: Locale.Language?, target: TargetLanguageOption) -> String {
        languagePairDescription(sourceCode: source?.minimalIdentifier, target: target)
    }

    public static func withLanguagePair(_ message: String, languagePair: String) -> String {
        let format = NSLocalizedString(
            "Language: %@\n%@",
            comment: "Apple Translate error prefix that shows current source and target languages"
        )
        return String(format: format, languagePair, message)
    }

    private static func sourceLabel(for sourceCode: String?) -> String {
        guard let sourceCode, !sourceCode.isEmpty else {
            return NSLocalizedString("Auto", comment: "Automatic source language label")
        }
        if let option = SourceLanguageOption(rawValue: sourceCode)
            ?? SourceLanguageOption(rawValue: String(sourceCode.prefix(2)))
        {
            return option.primaryLabel
        }
        let locale = Locale(identifier: sourceCode)
        return locale.localizedString(forIdentifier: sourceCode) ?? sourceCode
    }

    /// Heuristic: the Translation framework surfaces "language must be downloaded
    /// on the device" via TranslationErrorDomain (or via NSCocoaErrorDomain wrappers)
    /// with messages mentioning download / device. Match on substrings across the
    /// localized description chain so we catch all locales the system might emit.
    public static func isLanguagePackMissing(_ error: Error) -> Bool {
        isLanguagePackMissing(error as NSError)
    }

    private static func isLanguagePackMissing(_ error: NSError) -> Bool {
        var messages: [String] = [error.localizedDescription]
        if let reason = error.localizedFailureReason { messages.append(reason) }
        if let suggestion = error.localizedRecoverySuggestion { messages.append(suggestion) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            messages.append(underlying.localizedDescription)
            if let reason = underlying.localizedFailureReason { messages.append(reason) }
        }

        let needles = [
            "download",
            "must be downloaded",
            "not installed",
            "notinstalled",
            "下载",
            "未安装",
            "設備",
            "设备",
            "デバイス",
            "ダウンロード",
        ]
        let haystack = messages.joined(separator: " ").lowercased()
        return needles.contains { haystack.contains($0.lowercased()) }
    }
}

// MARK: - Local Provider Errors

public enum LocalProviderError: LocalizedError {
    case notAvailable(String)
    case translationFailed(String)
    case unsupportedAction
    case unsupportedLanguagePair
    case languagePackNotInstalled(languagePair: String)
    case sameSourceAndTarget(language: String, languagePair: String?)
    case operationTimedOut(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case let .notAvailable(reason):
            return reason
        case let .translationFailed(reason):
            return reason
        case .unsupportedAction:
            return NSLocalizedString("This action is not supported by the selected provider", comment: "Unsupported action error")
        case .unsupportedLanguagePair:
            return NSLocalizedString(
                "Please try translating in the main window and wait for the system prompt to download the target language.",
                comment: "Shown when Apple Translate cannot translate because the language pack is not installed on device"
            )
        case let .languagePackNotInstalled(languagePair):
            let message = NSLocalizedString(
                "Apple Translate has not downloaded this language pair. Use Apple Translate in the main window once " +
                    "and wait for the system prompt to download the target language, then start realtime translation again.",
                comment: "Shown when realtime Apple Translate starts without the required language pack"
            )
            return AppleTranslationErrorFormatter.withLanguagePair(message, languagePair: languagePair)
        case let .sameSourceAndTarget(language, languagePair):
            let format = NSLocalizedString(
                "Source and target are both %@. Pick a different target language.",
                comment: "Apple Translate refused to translate from a language to itself"
            )
            let message = String(format: format, language)
            guard let languagePair else { return message }
            return AppleTranslationErrorFormatter.withLanguagePair(message, languagePair: languagePair)
        case let .operationTimedOut(seconds):
            let format = NSLocalizedString(
                "Apple Translate timed out after %d seconds. Please try again.",
                comment: "Shown when Apple Translate does not finish before the timeout"
            )
            return String(format: format, seconds)
        }
    }
}

// MARK: - SourceLanguageOption Extension

public extension SourceLanguageOption {
    /// Convert to optional Locale.Language for Translation API (nil for .auto)
    var localeLanguage: Locale.Language? {
        switch self {
        case .auto:
            return nil
        default:
            return Locale.Language(identifier: rawValue)
        }
    }
}

// MARK: - TargetLanguageOption Extension

public extension TargetLanguageOption {
    /// Convert to Locale.Language for Translation API
    var localeLanguage: Locale.Language {
        switch self {
        case .appLanguage:
            return Locale.Language(identifier: TargetLanguageOption.appLanguageIdentifier)
        default:
            return Locale.Language(identifier: rawValue)
        }
    }
}

#if os(macOS)
    public extension Notification.Name {
        /// Posted after `TranslationSession.prepareTranslation()` completes (language pack
        /// downloaded or already installed). The macOS host app uses this to hide the
        /// auxiliary translation window after the download sheet is dismissed.
        static let appleTranslationPrepareCompleted = Notification.Name("appleTranslationPrepareCompleted")
    }
#endif
