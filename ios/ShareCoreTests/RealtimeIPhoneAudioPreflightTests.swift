//
//  RealtimeIPhoneAudioPreflightTests.swift
//  ShareCoreTests
//

#if os(iOS)
    import Foundation
    import Testing

    @testable import ShareCore

    @Suite("RealtimeIPhoneAudioPreflight")
    struct RealtimeIPhoneAudioPreflightTests {
        @Test("Requires explicit source language")
        func requiresExplicitSourceLanguage() {
            let failure = RealtimeIPhoneAudioPreflight.validate(
                sourceLanguage: .auto,
                targetLanguage: .japanese,
                speechAuthorization: .authorized,
                translationPackStatus: .installed
            )

            #expect(failure == .missingSourceLanguage)
        }

        @Test("Requires explicit target language")
        func requiresExplicitTargetLanguage() {
            let failure = RealtimeIPhoneAudioPreflight.validate(
                sourceLanguage: .english,
                targetLanguage: .appLanguage,
                speechAuthorization: .authorized,
                translationPackStatus: .installed
            )

            #expect(failure == .missingTargetLanguage)
        }

        @Test("Requires speech authorization")
        func requiresSpeechAuthorization() {
            let failure = RealtimeIPhoneAudioPreflight.validate(
                sourceLanguage: .english,
                targetLanguage: .japanese,
                speechAuthorization: .denied,
                translationPackStatus: .installed
            )

            #expect(failure == .speechNotAuthorized)
        }

        @Test("Requires installed Apple Translate language pack")
        func requiresInstalledAppleTranslateLanguagePack() {
            let failure = RealtimeIPhoneAudioPreflight.validate(
                sourceLanguage: .english,
                targetLanguage: .japanese,
                speechAuthorization: .authorized,
                translationPackStatus: .supported
            )

            #expect(failure == .translationPackNotInstalled)
        }

        @Test("Passes when local speech and translation are ready")
        func passesWhenLocalSpeechAndTranslationAreReady() {
            let failure = RealtimeIPhoneAudioPreflight.validate(
                sourceLanguage: .english,
                targetLanguage: .japanese,
                speechAuthorization: .authorized,
                translationPackStatus: .installed
            )

            #expect(failure == nil)
        }

        @Test("Broadcast picker wait times out without extension heartbeat")
        func broadcastPickerWaitTimesOut() {
            let startedAt = Date(timeIntervalSince1970: 100)
            let state = RealtimeBroadcastState(
                phase: .waiting,
                lastUpdatedAt: startedAt
            )

            #expect(!RealtimeSessionStore.isIPhoneAudioBroadcastWaitTimedOut(
                state,
                referenceDate: startedAt.addingTimeInterval(14.9)
            ))
            #expect(RealtimeSessionStore.isIPhoneAudioBroadcastWaitTimedOut(
                state,
                referenceDate: startedAt.addingTimeInterval(15)
            ))
        }

        @Test("Active broadcast never uses picker wait timeout")
        func activeBroadcastDoesNotTimeOutAsPickerWait() {
            let startedAt = Date(timeIntervalSince1970: 100)
            let state = RealtimeBroadcastState(
                phase: .broadcasting,
                audioSampleCount: 1,
                lastUpdatedAt: startedAt
            )

            #expect(!RealtimeSessionStore.isIPhoneAudioBroadcastWaitTimedOut(
                state,
                referenceDate: startedAt.addingTimeInterval(60)
            ))
        }
    }
#endif
