//
//  RealtimeTranslationSourceTrackerTests.swift
//  ShareCoreTests
//

import Testing

@testable import ShareCore

@Suite("RealtimeTranslationSourceTracker")
struct RealtimeTranslationSourceTrackerTests {
    @Test("Does not reschedule unchanged completed source text")
    func doesNotRescheduleUnchangedCompletedSourceText() {
        var tracker = RealtimeTranslationSourceTracker()

        let firstSchedule = tracker.shouldSchedule("I think this works.")
        let duplicateSchedule = tracker.shouldSchedule("I think this works.")
        let nextSchedule = tracker.shouldSchedule("I think this works. However, this is new.")

        #expect(firstSchedule)
        #expect(!duplicateSchedule)
        #expect(nextSchedule)
    }

    @Test("Allows same source text after reset")
    func allowsSameSourceTextAfterReset() {
        var tracker = RealtimeTranslationSourceTracker()

        let firstSchedule = tracker.shouldSchedule("I think this works.")
        tracker.reset()
        let rescheduleAfterReset = tracker.shouldSchedule("I think this works.")

        #expect(firstSchedule)
        #expect(rescheduleAfterReset)
    }
}
