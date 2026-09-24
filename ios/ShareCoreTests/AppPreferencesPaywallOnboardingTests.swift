//
//  AppPreferencesPaywallOnboardingTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@MainActor
@Suite("Paywall onboarding preferences", .serialized)
struct AppPreferencesPaywallOnboardingTests {
    @Test("iOS paywall onboarding defaults to unseen")
    func defaultsToUnseen() throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(defaults: defaults)

        #expect(!preferences.hasSeenIOSPaywallOnboarding)
    }

    @Test("iOS paywall onboarding seen state persists")
    func seenStatePersists() throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(defaults: defaults)

        preferences.setHasSeenIOSPaywallOnboarding(true)

        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.hasSeenIOSPaywallOnboarding)
    }

    @Test("refresh updates iOS paywall onboarding seen state")
    func refreshUpdatesSeenState() throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(defaults: defaults)

        defaults.set(true, forKey: "has_seen_ios_paywall_onboarding")
        preferences.refreshFromDefaults()

        #expect(preferences.hasSeenIOSPaywallOnboarding)
    }

    @Test("default translation onboarding starts unseen and incomplete")
    func defaultTranslationOnboardingDefaults() throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(defaults: defaults)

        #expect(!preferences.hasSeenDefaultTranslationOnboarding)
        #expect(!preferences.hasCompletedDefaultTranslationTrial)
        #expect(preferences.lastDefaultTranslationTrialAt == nil)
    }

    @Test("default translation onboarding seen state persists")
    func defaultTranslationOnboardingSeenStatePersists() throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(defaults: defaults)

        preferences.setHasSeenDefaultTranslationOnboarding(true)

        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.hasSeenDefaultTranslationOnboarding)
    }

    @Test("refresh updates default translation onboarding seen state")
    func refreshUpdatesDefaultTranslationOnboardingSeenState() throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(defaults: defaults)

        defaults.set(true, forKey: "ios_default_translation_onboarding_seen")
        preferences.refreshFromDefaults()

        #expect(preferences.hasSeenDefaultTranslationOnboarding)
    }

    @Test("default translation trial invocation persists completion and timestamp")
    func defaultTranslationTrialInvocationPersists() throws {
        let defaults = try makeDefaults()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let preferences = AppPreferences(defaults: defaults)

        preferences.recordDefaultTranslationTrialInvocation(date: date)

        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.hasCompletedDefaultTranslationTrial)
        #expect(reloaded.lastDefaultTranslationTrialAt == date)
    }

    @Test("refresh updates default translation trial completion")
    func refreshUpdatesDefaultTranslationTrialCompletion() throws {
        let defaults = try makeDefaults()
        let date = Date(timeIntervalSince1970: 1_800_000_100)
        let preferences = AppPreferences(defaults: defaults)

        defaults.set(true, forKey: "ios_default_translation_trial_completed")
        defaults.set(date, forKey: "ios_default_translation_trial_last_invoked_at")
        preferences.refreshFromDefaults()

        #expect(preferences.hasCompletedDefaultTranslationTrial)
        #expect(preferences.lastDefaultTranslationTrialAt == date)
    }

    @Test("satisfaction prompt ignores old shown-only cooldown")
    func satisfactionPromptIgnoresOldShownOnlyCooldown() throws {
        let defaults = try makeDefaults()
        defaults.set("3.4.27", forKey: "satisfaction_prompt_last_version")
        defaults.set(Date(), forKey: "satisfaction_prompt_last_date")

        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.shouldShowSatisfactionPrompt)
    }

    @Test("satisfaction prompt response starts seven day cooldown")
    func satisfactionPromptResponseStartsSevenDayCooldown() throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(defaults: defaults)

        preferences.markSatisfactionPromptResponded()

        #expect(!preferences.shouldShowSatisfactionPrompt)

        defaults.set(Date().addingTimeInterval(-8 * 24 * 3600), forKey: "satisfaction_prompt_last_response_date")
        #expect(preferences.shouldShowSatisfactionPrompt)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AppPreferencesPaywallOnboardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
