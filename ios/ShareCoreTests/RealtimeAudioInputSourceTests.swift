//
//  RealtimeAudioInputSourceTests.swift
//  ShareCoreTests
//

#if os(macOS) || os(iOS)
    import Testing

    @testable import ShareCore

    @Suite("RealtimeAudioInputSource")
    struct RealtimeAudioInputSourceTests {
        @Test("Defines platform-specific input sources")
        func definesPlatformSpecificInputSources() {
            #if os(iOS)
                #expect(RealtimeAudioInputSource.default == .microphone)
                #expect(RealtimeAudioInputSource.allCases == [.microphone])
                #expect(RealtimeAudioInputSource.iphoneAudio.title == "iPhone Audio")
            #elseif os(macOS)
                #expect(RealtimeAudioInputSource.default == .macAudio)
                #expect(RealtimeAudioInputSource.allCases == [.macAudio, .microphone])
            #endif
        }

        @Test("Defines supported realtime options for each input source")
        func definesSupportedRealtimeOptions() {
            #if os(iOS)
                #expect(
                    RealtimeAudioInputSource.microphone.supportedTranslationProviders == RealtimeTranslationProvider
                        .availableCases
                )
                #expect(RealtimeAudioInputSource.microphone.supportedRecognitionModels == [.appleSpeech])
                #expect(RealtimeAudioInputSource.iphoneAudio.supportedTranslationProviders == [.appleTranslator])
                #expect(RealtimeAudioInputSource.iphoneAudio.supportedRecognitionModels == [.appleSpeech])
            #elseif os(macOS)
                #expect(
                    RealtimeAudioInputSource.macAudio.supportedTranslationProviders == RealtimeTranslationProvider
                        .availableCases
                )
                #expect(RealtimeAudioInputSource.macAudio.supportedRecognitionModels == RecognitionModelStore.availableModels)
                #expect(
                    RealtimeAudioInputSource.microphone.supportedTranslationProviders == RealtimeTranslationProvider
                        .availableCases
                )
                #expect(RealtimeAudioInputSource.microphone.supportedRecognitionModels == RecognitionModelStore.availableModels)
            #endif
        }
    }
#endif
