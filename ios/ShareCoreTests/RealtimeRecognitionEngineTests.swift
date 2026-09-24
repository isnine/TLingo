//
//  RealtimeRecognitionEngineTests.swift
//  ShareCoreTests
//

#if os(macOS) || os(iOS)
    import Testing

    @testable import ShareCore

    @Suite("RealtimeRecognitionEngine")
    struct RealtimeRecognitionEngineTests {
        @Test("Defines default and permission behavior")
        func definesDefaultAndPermissionBehavior() {
            #expect(RealtimeRecognitionEngine.default == .appleSpeech)
            #expect(RealtimeRecognitionEngine.allCases == [.appleSpeech])
            #expect(RealtimeRecognitionEngine.appleSpeech.requiresSpeechRecognitionPermission)
        }
    }
#endif
