//
//  RealtimeSetupPromptRequirementTests.swift
//  ShareCoreTests
//

import Testing

@testable import ShareCore

@Suite("RealtimeSetupPromptRequirement")
struct RealtimeSetupPromptRequirementTests {
    @Test("Does not show language prompt while a permission prompt is active")
    func permissionPromptTakesPriority() {
        let requirement = RealtimeSetupPromptRequirement.evaluate(
            hasMissingPermission: true,
            sourceLanguage: .auto,
            targetLanguage: .appLanguage
        )

        #expect(requirement == .none)
    }

    @Test("Shows language prompt when permissions are satisfied and source is missing")
    func showsPromptWhenSourceIsMissing() {
        let requirement = RealtimeSetupPromptRequirement.evaluate(
            hasMissingPermission: false,
            sourceLanguage: .auto,
            targetLanguage: .japanese
        )

        #expect(requirement == .languageSelection)
    }

    @Test("Shows language prompt when permissions are satisfied and target is missing")
    func showsPromptWhenTargetIsMissing() {
        let requirement = RealtimeSetupPromptRequirement.evaluate(
            hasMissingPermission: false,
            sourceLanguage: .english,
            targetLanguage: .appLanguage
        )

        #expect(requirement == .languageSelection)
    }

    @Test("Does not show language prompt when permissions and languages are ready")
    func hidesPromptWhenReady() {
        let requirement = RealtimeSetupPromptRequirement.evaluate(
            hasMissingPermission: false,
            sourceLanguage: .english,
            targetLanguage: .japanese
        )

        #expect(requirement == .none)
    }

    @Test("Transcription only requires source language")
    func transcriptionOnlyRequiresSourceLanguage() {
        #expect(RealtimeSetupPromptRequirement.hasRequiredLanguageSelection(
            sourceLanguage: .english,
            targetLanguage: .appLanguage,
            requiresTargetLanguage: false
        ))
        #expect(!RealtimeSetupPromptRequirement.hasRequiredLanguageSelection(
            sourceLanguage: .auto,
            targetLanguage: .appLanguage,
            requiresTargetLanguage: false
        ))
    }
}
