//
//  RealtimeTranslationSchedulingPolicyTests.swift
//  ShareCoreTests
//

#if os(macOS) || os(iOS)
    import Testing

    @testable import ShareCore

    @Suite("RealtimeTranslationSchedulingPolicy")
    struct RealtimeTranslationSchedulingPolicyTests {
        @Test("Apple translation providers throttle partial previews")
        func appleTranslationProvidersThrottlePartialPreviews() {
            #expect(RealtimeTranslationSchedulingPolicy.cadenceInterval(for: .appleTranslator) == 0.5)
            #expect(RealtimeTranslationSchedulingPolicy.cadenceInterval(for: .appleTranslationRealtime) == 0.35)
        }
    }
#endif
