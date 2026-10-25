//
//  OnboardingRouteTests.swift
//  ShareCoreTests
//

@testable import ShareCore
import Testing

@Suite("Onboarding route")
struct OnboardingRouteTests {
    @Test("An empty selection keeps the words-only flow")
    func emptySelectionFallsBackToWords() {
        let route = OnboardingRoute(scenarios: [])

        #expect(route.scenarios == [.words])
        #expect(route.phases == [.words])
        #expect(route.realtimeInputs.isEmpty)
        #expect(!route.includesRealtime)
        #expect(!route.endsWithFirstRunPaywall)
    }

    @Test("Words only runs the words flow")
    func wordsOnly() {
        let route = OnboardingRoute(scenarios: [.words])

        #expect(route.phases == [.words])
        #expect(!route.endsWithFirstRunPaywall)
    }

    @Test("Live conversations only runs Realtime with the microphone, then the first-run paywall")
    func liveConversationsOnly() {
        let route = OnboardingRoute(scenarios: [.liveConversations])

        #expect(route.phases == [.realtime])
        #expect(route.realtimeInputs == [.microphone])
        #expect(route.endsWithFirstRunPaywall)
    }

    @Test("Shows and videos only runs Realtime with iPhone Audio")
    func showsOnly() {
        let route = OnboardingRoute(scenarios: [.showsAndVideos])

        #expect(route.phases == [.realtime])
        #expect(route.realtimeInputs == [.iphoneAudio])
        #expect(route.endsWithFirstRunPaywall)
    }

    @Test("Both Realtime scenarios try the microphone before iPhone Audio")
    func bothRealtimeScenariosKeepInputOrder() {
        let route = OnboardingRoute(scenarios: [.showsAndVideos, .liveConversations])

        #expect(route.realtimeInputs == [.microphone, .iphoneAudio])
        #expect(route.phases == [.realtime])
    }

    @Test("Realtime runs before the words flow so the premium offer stays last")
    func realtimeRunsBeforeWords() {
        let route = OnboardingRoute(scenarios: [.words, .liveConversations, .showsAndVideos])

        #expect(route.phases == [.realtime, .words])
        #expect(!route.endsWithFirstRunPaywall)
    }
}

@Suite("Onboarding practice phrase")
struct OnboardingPracticePhraseTests {
    @Test("An exact language code wins")
    func exactCode() {
        #expect(OnboardingPracticePhrase.phrase(for: .traditionalChinese) == "請問去車站怎麼走？")
        #expect(OnboardingPracticePhrase.phrase(for: .simplifiedChinese) == "请问去车站怎么走？")
    }

    @Test("A regional code falls back to its base language")
    func baseLanguageFallback() {
        #expect(
            OnboardingPracticePhrase.phrase(for: .englishUnitedKingdom)
                == OnboardingPracticePhrase.phrase(for: .english)
        )
        #expect(OnboardingPracticePhrase.phrase(for: .english) != nil)
    }

    @Test("Auto has no phrase")
    func autoHasNoPhrase() {
        #expect(OnboardingPracticePhrase.phrase(for: .auto) == nil)
    }
}
