//
//  HomeViewModelLanguageResolutionTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("HomeViewModel target language resolution")
struct HomeViewModelLanguageResolutionTests {
    @Test("Manual target is not marked as redirected even when it matches source")
    func manualTargetDoesNotRedirect() {
        let result = HomeViewModel.resolveTargetLanguage(
            preferred: .english,
            override: nil,
            sourceCode: "en",
            matchCandidates: [.english, .simplifiedChinese]
        )

        #expect(result.target == .english)
        #expect(result.displayTarget == nil)
    }

    @Test("Match target resolves away from source")
    func matchTargetRedirectsAwayFromSource() {
        let result = HomeViewModel.resolveTargetLanguage(
            preferred: .appLanguage,
            override: nil,
            sourceCode: "zh-Hans",
            matchCandidates: [.simplifiedChinese, .english]
        )

        #expect(result.target == .english)
        #expect(result.displayTarget == .english)
    }

    @Test("Manual override wins over Match resolution")
    func manualOverrideWinsOverMatch() {
        let result = HomeViewModel.resolveTargetLanguage(
            preferred: .appLanguage,
            override: .japanese,
            sourceCode: "ja",
            matchCandidates: [.japanese, .english]
        )

        #expect(result.target == .japanese)
        #expect(result.displayTarget == .japanese)
    }

    @Test("Automatic target flags fallback only when the first language is skipped")
    func automaticTargetFlagsFallbackWhenFirstLanguageIsSkipped() throws {
        let chinese = try #require(SourceLanguageOption(rawValue: "zh-Hans"))
        let english = try #require(SourceLanguageOption(rawValue: "en"))

        let fallback = HomeViewModel.resolveLanguages(
            text: "会议改到周四下午了",
            sourcePreference: chinese,
            preferredTarget: .appLanguage,
            override: nil,
            matchCandidates: [.simplifiedChinese, .english]
        )
        #expect(fallback.target == .english)
        #expect(fallback.isMatchFallback)

        let primary = HomeViewModel.resolveLanguages(
            text: "The meeting moved to Thursday",
            sourcePreference: english,
            preferredTarget: .appLanguage,
            override: nil,
            matchCandidates: [.simplifiedChinese, .english]
        )
        #expect(primary.target == .simplifiedChinese)
        #expect(!primary.isMatchFallback)
    }

    @Test("Minimal Chinese detection code maps to Simplified Chinese source")
    func minimalChineseCodeMapsToSimplifiedChinese() {
        let result = HomeViewModel.resolveLanguages(
            text: "会议改到周四下午了，请大家准时参加",
            sourcePreference: .auto,
            preferredTarget: .appLanguage,
            override: nil,
            matchCandidates: [.simplifiedChinese, .english]
        )
        #expect(result.displaySource == SourceLanguageOption(rawValue: "zh-Hans"))
        #expect(result.target == .english)
    }

    @Test("Manual override is never reported as an automatic target fallback")
    func manualOverrideIsNotFallback() throws {
        let chinese = try #require(SourceLanguageOption(rawValue: "zh-Hans"))

        let result = HomeViewModel.resolveLanguages(
            text: "会议改到周四下午了",
            sourcePreference: chinese,
            preferredTarget: .appLanguage,
            override: .japanese,
            matchCandidates: [.simplifiedChinese, .english]
        )
        #expect(result.target == .japanese)
        #expect(!result.isMatchFallback)
    }

    @Test("Translation equality preserves Chinese script")
    func translationEqualityPreservesChineseScript() {
        #expect(SourceLanguageDetector.languagesAreSame("zh-Hans", "zh-Hant") == false)
        #expect(SourceLanguageDetector.languagesAreSame("zh-Hant", "zh-Hans") == false)
        #expect(SourceLanguageDetector.languagesAreSame("zh-Hans", "zh-CN"))
        #expect(SourceLanguageDetector.languagesAreSame("en-US", "en"))
        #expect(SourceLanguageDetector.languagesAreSame("ja", "en") == false)
    }
}

@Suite("HomeViewModel request generation")
struct HomeViewModelRequestGenerationTests {
    @Test("A new generation rejects delayed retry work")
    func newGenerationRejectsDelayedRetry() {
        let firstGeneration = UUID()
        let firstToken = UUID()
        let retryToken = UUID()
        let secondGeneration = UUID()
        let secondToken = UUID()
        var tracker = HomeViewModel.RequestGenerationTracker()

        tracker.begin(generation: firstGeneration, runTokens: ["model": firstToken])
        tracker.retry(runID: "model", token: retryToken)
        #expect(tracker.accepts(generation: firstGeneration, runID: "model", token: retryToken))

        tracker.begin(generation: secondGeneration, runTokens: ["model": secondToken])

        #expect(tracker.accepts(generation: firstGeneration, runID: "model", token: retryToken) == false)
        #expect(tracker.accepts(generation: secondGeneration, runID: "model", token: secondToken))
    }

    @Test("Apple retry token is accepted only for its run")
    func appleRetryTokenIsRunScoped() {
        let generation = UUID()
        let appleToken = UUID()
        let cloudToken = UUID()
        let retryToken = UUID()
        var tracker = HomeViewModel.RequestGenerationTracker()

        tracker.begin(generation: generation, runTokens: [
            ModelConfig.appleTranslateID: appleToken,
            "cloud": cloudToken,
        ])
        tracker.retry(runID: ModelConfig.appleTranslateID, token: retryToken)

        #expect(tracker.accepts(
            generation: generation,
            runID: ModelConfig.appleTranslateID,
            token: retryToken
        ))
        #expect(tracker.accepts(
            generation: generation,
            runID: ModelConfig.appleTranslateID,
            token: appleToken
        ) == false)
        #expect(tracker.accepts(
            generation: generation,
            runID: "cloud",
            token: retryToken
        ) == false)
    }

    @Test("Cancellation rejects every provider run")
    func cancellationRejectsEveryRun() {
        let generation = UUID()
        let appleToken = UUID()
        let microsoftToken = UUID()
        var tracker = HomeViewModel.RequestGenerationTracker()

        tracker.begin(generation: generation, runTokens: [
            ModelConfig.appleTranslateID: appleToken,
            ModelConfig.microsoftTranslateID: microsoftToken,
        ])
        tracker.cancel()

        #expect(tracker.accepts(
            generation: generation,
            runID: ModelConfig.appleTranslateID,
            token: appleToken
        ) == false)
        #expect(tracker.accepts(
            generation: generation,
            runID: ModelConfig.microsoftTranslateID,
            token: microsoftToken
        ) == false)
    }

    @Test("Retry completion clears only its retry task")
    func retryCompletionDoesNotOwnPrimaryTask() {
        let runToken = UUID()
        let primary = HomeViewModel.RequestTaskOwner.primary
        let retry = HomeViewModel.RequestTaskOwner.retry(runID: "model", runToken: runToken)

        #expect(HomeViewModel.taskCleanup(
            for: primary,
            generationMatches: true,
            retryMatches: false
        ) == .primary)
        #expect(HomeViewModel.taskCleanup(
            for: retry,
            generationMatches: true,
            retryMatches: true
        ) == .retry(runID: "model"))
        #expect(HomeViewModel.taskCleanup(
            for: retry,
            generationMatches: true,
            retryMatches: false
        ) == .none)
    }
}
