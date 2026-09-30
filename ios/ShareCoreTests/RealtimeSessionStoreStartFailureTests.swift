#if os(macOS) || os(iOS)
    import Foundation
    import Testing
    #if canImport(Translation)
        import Translation
    #endif

    @testable import ShareCore

    @Suite("RealtimeSessionStore start failure")
    struct RealtimeSessionStoreStartFailureTests {
        @Test("Apple Speech recognizer initialization failure is actionable")
        func appleSpeechRecognizerInitializationFailureIsActionable() {
            let message = RealtimeSessionStore.startFailureAlertMessage(
                for: NSError(domain: "kLSRErrorDomain", code: 300)
            )

            #expect(message.contains("Apple Speech failed to initialize the recognizer."))
            #expect(message.contains("change the source language"))
        }

        @Test("Apple Speech missing model failure is actionable")
        func appleSpeechMissingModelFailureIsActionable() {
            let message = RealtimeSessionStore.startFailureAlertMessage(
                for: NSError(domain: "SFSpeechErrorDomain", code: 4)
            )

            #expect(message.contains("Apple Speech could not load the recognition model"))
        }

        @Test("Opaque realtime errors include domain and code")
        func opaqueRealtimeErrorsIncludeDomainAndCode() {
            let message = RealtimeSessionStore.startFailureAlertMessage(
                for: NSError(
                    domain: "SpeechAnalyzerErrorDomain",
                    code: 42,
                    userInfo: [NSLocalizedDescriptionKey: "The analyzer stopped unexpectedly."]
                )
            )

            #expect(message.contains("The analyzer stopped unexpectedly."))
            #expect(message.contains("SpeechAnalyzerErrorDomain"))
            #expect(message.contains("42"))
        }

        #if os(macOS)
            @Test("Mac Audio runtime stop message is actionable")
            func macAudioRuntimeStopMessageIsActionable() {
                let message = RealtimeSessionStore.startFailureAlertMessage(
                    for: RealtimeCaptureError.systemAudioCaptureStopped
                )

                #expect(message.contains("Mac Audio capture stopped unexpectedly."))
                #expect(message.contains("start realtime again"))
            }
        #endif

        @Test("Speech runtime end message is actionable")
        func speechRuntimeEndMessageIsActionable() {
            let message = RealtimeSessionStore.startFailureAlertMessage(
                for: RealtimeCaptureError.speechRecognitionEndedUnexpectedly
            )

            #expect(message.contains("Speech recognition ended unexpectedly."))
            #expect(message.contains("start realtime again"))
        }

        #if os(iOS)
            @Test("iPhone Audio failed state surfaces extension error")
            func iphoneAudioFailedStateSurfacesExtensionError() {
                let alert = RealtimeSessionStore.iPhoneAudioBroadcastFailureAlert(
                    for: RealtimeBroadcastState(
                        sessionID: "session-1",
                        phase: .failed,
                        errorMessage: "Speech recognition crashed inside the broadcast extension."
                    ),
                    referenceDate: Date()
                )

                #expect(alert.title == "iPhone Audio Failed")
                #expect(alert.message.contains("Speech recognition crashed inside the broadcast extension."))
            }

            @Test("iPhone Audio stale active state explains extension disconnect")
            func iphoneAudioStaleActiveStateExplainsExtensionDisconnect() {
                let alert = RealtimeSessionStore.iPhoneAudioBroadcastFailureAlert(
                    for: RealtimeBroadcastState(
                        sessionID: "session-1",
                        phase: .broadcasting,
                        audioSampleCount: 12,
                        lastUpdatedAt: Date(timeIntervalSince1970: 100)
                    ),
                    referenceDate: Date(timeIntervalSince1970: 109)
                )

                #expect(alert.message.contains("stopped reporting status"))
                #expect(alert.message.contains("broadcasting"))
                #expect(alert.message.contains("12"))
            }
        #endif

        @Test("Runtime cancellation errors are ignored")
        func runtimeCancellationErrorsAreIgnored() {
            #expect(RealtimeSessionStore.isCancellationError(CancellationError()))
            #expect(RealtimeSessionStore.isCancellationError(URLError(.cancelled)))
            #expect(RealtimeSessionStore.isCancellationError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
            #expect(!RealtimeSessionStore.isCancellationError(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        }

        #if canImport(Translation)
            @available(iOS 17.4, macOS 14.4, *)
            @Test("Apple Translate language pair without a downloaded pack blocks realtime")
            func appleTranslateSupportedLanguagePairBlocksRealtime() {
                let error = RealtimeSessionStore.appleTranslateLanguagePreflightFailure(
                    status: .supported,
                    languagePair: "English -> 简体中文"
                )

                guard case .languagePackNotInstalled? = error else {
                    Issue.record("Expected languagePackNotInstalled, got \(String(describing: error))")
                    return
                }
            }
        #endif

        @Test("Transcript segmentation follows completed item boundaries")
        func transcriptSegmentationFollowsCompletedItemBoundaries() {
            let segments = RealtimeSessionStore.transcriptSegments(from: "First. Second.\n\nThird.")

            #expect(segments == ["First. Second.", "Third."])
        }
    }
#endif
